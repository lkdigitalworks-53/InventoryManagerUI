#include "PkceGenerator.h"

#include <QCryptographicHash>
#include <QRandomGenerator>

PkceGenerator::PkceGenerator(QObject *parent)
    : QObject(parent)
{
}

QString PkceGenerator::newVerifier()
{
    static const char kUnreserved[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    constexpr int kLen = 64;
    constexpr int kSetSize = sizeof(kUnreserved) - 1;  // exclude trailing NUL

    QString out;
    out.reserve(kLen);
    for (int i = 0; i < kLen; ++i) {
        const quint32 r = QRandomGenerator::system()->bounded(kSetSize);
        out.append(QChar::fromLatin1(kUnreserved[r]));
    }
    return out;
}

QString PkceGenerator::challenge(const QString &verifier)
{
    const QByteArray digest =
        QCryptographicHash::hash(verifier.toUtf8(), QCryptographicHash::Sha256);
    // base64url, no padding (RFC 7636 §4.2).
    return QString::fromLatin1(
        digest.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}
