#pragma once

#include <QObject>
#include <QString>
#include <QUrl>

// ImageProcessor — compresses + EXIF-rotates + resizes a picked image to a
// JPEG file suitable for upload (or local persistence). Returned URL points
// at the cache folder so QML Image components can render immediately.
class ImageProcessor final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(ImageProcessor)

public:
    explicit ImageProcessor(QObject *parent = nullptr);
    ~ImageProcessor() override = default;

    // Compress source to JPEG, longest edge clamped to maxEdge, quality 1..100.
    // Returns a "file:///…" URL of the produced file, empty string on failure.
    Q_INVOKABLE QString compressForUpload(const QUrl &source,
                                          int maxEdge = 800,
                                          int qualityJpeg = 75);

    // Persist a source file (already compressed or remote URL) into the app's
    // local data folder under products/{productId}.jpg and return its file URL.
    // Used while Firebase Storage isn't available — local-first storage path.
    Q_INVOKABLE QString persistLocalCopy(const QString &productId, const QUrl &source);

    // Remove a previously persisted local file.
    Q_INVOKABLE bool removeLocalCopy(const QString &productId);

Q_SIGNALS:
    void compressionFailed(const QString &reason);

private:
    static QString cacheDir();
    static QString localPhotosDir();
};
