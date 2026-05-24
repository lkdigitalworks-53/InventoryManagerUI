#include "OAuthServer.h"

#include <QHostAddress>
#include <QTcpSocket>

// Inline HTML+JS page served at GET /auth.
// Reads the id_token from the URL fragment (which never leaves the browser)
// and POSTs it to the local /token endpoint, then shows a completion message.
static const char s_extractorHtml[] =
    "<!DOCTYPE html>"
    "<html lang='en'><head><meta charset='utf-8'>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
    "<title>Signing in...</title>"
    "<style>"
    "body{font-family:system-ui,sans-serif;background:#f0f9ff;"
    "display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}"
    ".card{background:#fff;border-radius:12px;padding:40px 32px;max-width:420px;"
    "text-align:center;box-shadow:0 4px 24px #0002}"
    "h2{color:#1e40af;margin:0 0 8px}p{color:#6b7280;margin:0}"
    "</style></head>"
    "<body><div class='card'>"
    "<h2 id='title'>&#8987; Completing sign-in&hellip;</h2>"
    "<p id='msg'>Please wait while we finalise your session.</p>"
    "</div>"
    "<script>"
    "(function(){"
    "  var f=location.hash.substring(1),p={};"
    "  f.split('&').forEach(function(x){"
    "    var kv=x.split('=');"
    "    if(kv.length===2) p[kv[0]]=decodeURIComponent(kv[1].replace(/\\+/g,' '));"
    "  });"
    "  function ok(){document.getElementById('title').textContent='\u2705 Signed in!';"
    "                document.getElementById('msg').textContent='You may close this tab and return to the app.';}"
    "  function fail(e){document.getElementById('title').textContent='\u274c Sign-in failed';"
    "                   document.getElementById('msg').textContent=e||'Please try again.';}"
    "  if(!p.id_token){fail('No token in response.');return;}"
    "  var xhr=new XMLHttpRequest();"
    "  xhr.open('POST','/token',true);"
    "  xhr.setRequestHeader('Content-Type','text/plain;charset=utf-8');"
    "  xhr.onload=function(){if(xhr.status===200)ok();else fail('Server error '+xhr.status);};"
    "  xhr.onerror=function(){fail('Network error.');};"
    "  xhr.send(p.id_token);"
    "})();"
    "</script>"
    "</body></html>";

OAuthServer::OAuthServer(QObject *parent)
    : QObject(parent)
    , m_server(new QTcpServer(this))
{
    connect(m_server, &QTcpServer::newConnection,
            this,     &OAuthServer::onNewConnection);
}

OAuthServer::~OAuthServer()
{
    stop();
}

int OAuthServer::port() const noexcept
{
    return m_port;
}

bool OAuthServer::isListening() const noexcept
{
    return m_server->isListening();
}

QString OAuthServer::redirectUri() const
{
    if (!isListening())
        return {};
    return QStringLiteral("http://127.0.0.1:%1/auth").arg(m_port);
}

bool OAuthServer::start()
{
    if (m_server->isListening())
        return true;

    // Try the fixed port first, then a small fallback range.
    for (int p = kDefaultPort; p < kDefaultPort + 5; ++p) {
        if (m_server->listen(QHostAddress::LocalHost, static_cast<quint16>(p))) {
            m_port = p;
            emit portChanged();
            return true;
        }
    }

    emit serverError(m_server->errorString());
    return false;
}

void OAuthServer::stop()
{
    if (!m_server->isListening())
        return;
    m_server->close();
    m_port = 0;
    emit portChanged();
}

void OAuthServer::onNewConnection()
{
    while (m_server->hasPendingConnections()) {
        auto *socket = m_server->nextPendingConnection();
        // Capture socket ptr; readyRead fires once enough data arrives.
        connect(socket, &QTcpSocket::readyRead, this, [this, socket]() {
            handleSocket(socket);
        });
        // Auto-cleanup on disconnect.
        connect(socket, &QTcpSocket::disconnected,
                socket, &QObject::deleteLater);
    }
}

void OAuthServer::handleSocket(QTcpSocket *socket)
{
    const QByteArray data    = socket->readAll();
    const int        lineEnd = data.indexOf('\n');
    const QByteArray firstLine = (lineEnd >= 0)
        ? data.left(lineEnd).trimmed()
        : data.trimmed();

    if (firstLine.startsWith("GET /auth")) {
        serveExtractorPage(socket);
    } else if (firstLine.startsWith("OPTIONS /token")) {
        // CORS preflight — browser sends this before the POST.
        writeResponse(socket, 204, "text/plain", {}, /*cors=*/true);
        socket->disconnectFromHost();
    } else if (firstLine.startsWith("POST /token")) {
        receiveToken(socket, data);
    } else {
        writeResponse(socket, 404, "text/plain", "Not found");
        socket->disconnectFromHost();
    }
}

void OAuthServer::serveExtractorPage(QTcpSocket *socket)
{
    const QByteArray body(s_extractorHtml,
                          static_cast<qsizetype>(sizeof(s_extractorHtml) - 1));
    writeResponse(socket, 200, "text/html; charset=utf-8", body);
    socket->disconnectFromHost();
}

void OAuthServer::receiveToken(QTcpSocket *socket, const QByteArray &request)
{
    // HTTP body follows the blank line (\r\n\r\n or \n\n).
    int idx = request.indexOf("\r\n\r\n");
    if (idx < 0)
        idx = request.indexOf("\n\n");

    const QString token = (idx >= 0)
        ? QString::fromUtf8(request.mid(idx).trimmed())
        : QString();

    writeResponse(socket, 200, "text/plain", "OK", /*cors=*/true);
    socket->flush();
    socket->disconnectFromHost();

    if (!token.isEmpty()) {
        stop(); // Release port immediately; we have our token.
        emit tokenReceived(token);
    }
}

void OAuthServer::writeResponse(QTcpSocket *socket, int status,
                                 const QByteArray &contentType,
                                 const QByteArray &body, bool cors)
{
    const QByteArray statusText = [status]() -> QByteArray {
        switch (status) {
        case 200: return "OK";
        case 204: return "No Content";
        case 404: return "Not Found";
        default:  return "Unknown";
        }
    }();

    QByteArray response;
    response.reserve(256 + body.size());
    response  = "HTTP/1.1 ";
    response += QByteArray::number(status);
    response += ' ';
    response += statusText;
    response += "\r\nContent-Type: ";
    response += contentType;
    response += "\r\nContent-Length: ";
    response += QByteArray::number(body.size());
    if (cors) {
        response += "\r\nAccess-Control-Allow-Origin: *"
                    "\r\nAccess-Control-Allow-Methods: POST, OPTIONS"
                    "\r\nAccess-Control-Allow-Headers: Content-Type";
    }
    response += "\r\nConnection: close\r\n\r\n";
    response += body;

    socket->write(response);
    socket->flush();
}