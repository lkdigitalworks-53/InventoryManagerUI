#pragma once

#include <QObject>
#include <QString>

// Clipboard — QML-invokable clipboard write. Felgo/QML exposes no clipboard
// API, so this thin wrapper over QGuiApplication::clipboard() backs the
// copy-User-ID action. Registered as the "Clipboard" context property.
class Clipboard final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(Clipboard)

public:
    explicit Clipboard(QObject *parent = nullptr);
    ~Clipboard() override = default;

    // Put `text` on the system clipboard. No-op if no clipboard is available.
    Q_INVOKABLE void copy(const QString &text);
};
