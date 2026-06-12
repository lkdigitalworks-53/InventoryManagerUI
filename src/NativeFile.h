#pragma once

#include <QObject>
#include <QString>
#include <QUrl>

// NativeFile — resolves any picked source (Android content:// URI, file:// URL,
// or plain path) to a readable local filesystem path by copying it into the app
// cache when necessary. Lets ImageProcessor / XlsxService keep operating on real
// file paths instead of content URIs (which they cannot stat or open directly).
class NativeFile final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(NativeFile)

public:
    explicit NativeFile(QObject *parent = nullptr);
    ~NativeFile() override = default;

    // Return a readable local file path for `uri`. For an already-local source
    // this returns its local path unchanged. For a content:// (or other
    // non-local) source it copies the bytes into the app cache and returns that
    // path. Returns an empty string on failure.
    Q_INVOKABLE QString toReadablePath(const QUrl &uri);

private:
    static QString cacheDir();
};
