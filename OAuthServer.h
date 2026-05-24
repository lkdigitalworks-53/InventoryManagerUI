#pragma once
#include <QObject>
#include <QTcpServer>

class OAuthServer : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int port READ port NOTIFY portChanged)

public:
    explicit OAuthServer(QObject *parent = nullptr);

    Q_INVOKABLE bool start();
    Q_INVOKABLE void stop();
    int port() const { return m_port; }

signals:
    void tokenReceived(const QString 
&
idToken);
    void portChanged();
    void serverError(const QString 
&
message);

private slots:
    void onNewConnection();

private:
    void handleSocket(class QTcpSocket *socket);

    QTcpServer *m_server = nullptr;
    int m_port = 0;
};

