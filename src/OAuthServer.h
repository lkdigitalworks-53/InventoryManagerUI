#pragma once

#include <QObject>
#include <QTcpServer>

class QTcpSocket;

// OAuthServer implements the RFC 8252 loopback-interface redirect pattern.
// Binds to 127.0.0.1 on a fixed port (8585), serves a JS extractor page that
// automatically POSTs the id_token back; emits tokenReceived() when done.
class OAuthServer final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(OAuthServer)
    Q_PROPERTY(int  port      READ port      NOTIFY portChanged FINAL)
    Q_PROPERTY(bool listening READ isListening NOTIFY portChanged FINAL)

public:
    explicit OAuthServer(QObject *parent = nullptr);
    ~OAuthServer() override;

    [[nodiscard]] int  port()        const noexcept;
    [[nodiscard]] bool isListening() const noexcept;

    Q_INVOKABLE bool start();
    Q_INVOKABLE void stop();
    Q_INVOKABLE [[nodiscard]] QString redirectUri() const;

Q_SIGNALS:
    void tokenReceived(const QString &idToken);
    void portChanged();
    void serverError(const QString &message);

private Q_SLOTS:
    void onNewConnection();

private:
    void handleSocket(QTcpSocket *socket);
    void serveExtractorPage(QTcpSocket *socket);
    void receiveToken(QTcpSocket *socket, const QByteArray &request);
    static void writeResponse(QTcpSocket *socket, int status,
                              const QByteArray &contentType,
                              const QByteArray &body,
                              bool cors = false);

    static constexpr int kDefaultPort = 8585;

    QTcpServer *m_server = nullptr;
    int         m_port   = 0;
};