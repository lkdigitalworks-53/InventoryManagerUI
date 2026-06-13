#pragma once

#include <QObject>
#include <QString>

// PkceGenerator — RFC 7636 PKCE helpers for the native Google auth-code flow.
// QML has no CSPRNG or SHA-256, so generate the verifier + S256 challenge here.
class PkceGenerator final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(PkceGenerator)

public:
    explicit PkceGenerator(QObject *parent = nullptr);
    ~PkceGenerator() override = default;

    // A high-entropy code_verifier: 64 chars from the unreserved set
    // [A-Z a-z 0-9 - . _ ~], per RFC 7636 §4.1.
    Q_INVOKABLE QString newVerifier();

    // base64url(SHA-256(verifier)) with no padding — the S256 code_challenge.
    Q_INVOKABLE QString challenge(const QString &verifier);
};
