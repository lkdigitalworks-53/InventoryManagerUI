#include "ImageProcessor.h"

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QImageWriter>
#include <QStandardPaths>

ImageProcessor::ImageProcessor(QObject *parent)
    : QObject(parent)
{
}

QString ImageProcessor::cacheDir()
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    QDir().mkpath(base);
    return base;
}

QString ImageProcessor::localPhotosDir()
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
                         + "/photos";
    QDir().mkpath(base);
    return base;
}

QString ImageProcessor::compressForUpload(const QUrl &source, int maxEdge, int qualityJpeg)
{
    const QString localPath = source.isLocalFile() ? source.toLocalFile() : source.toString();
    if (localPath.isEmpty() || !QFile::exists(localPath)) {
        emit compressionFailed(QStringLiteral("Source file not found: %1").arg(localPath));
        return {};
    }

    QImageReader reader(localPath);
    reader.setAutoTransform(true);  // applies EXIF orientation
    QImage image = reader.read();
    if (image.isNull()) {
        emit compressionFailed(QStringLiteral("Cannot decode image: %1").arg(reader.errorString()));
        return {};
    }

    if (maxEdge > 0) {
        const int longest = std::max(image.width(), image.height());
        if (longest > maxEdge) {
            image = (image.width() >= image.height())
                ? image.scaledToWidth(maxEdge, Qt::SmoothTransformation)
                : image.scaledToHeight(maxEdge, Qt::SmoothTransformation);
        }
    }

    const QString outPath = QStringLiteral("%1/photo_%2.jpg")
        .arg(cacheDir())
        .arg(QString::number(QDateTime::currentMSecsSinceEpoch()));

    QImageWriter writer(outPath, "jpeg");
    writer.setQuality(qBound(1, qualityJpeg, 100));
    if (!writer.write(image)) {
        emit compressionFailed(QStringLiteral("Cannot write JPEG: %1").arg(writer.errorString()));
        return {};
    }

    return QUrl::fromLocalFile(outPath).toString();
}

QString ImageProcessor::persistLocalCopy(const QString &productId, const QUrl &source)
{
    if (productId.isEmpty()) {
        emit compressionFailed(QStringLiteral("Missing productId"));
        return {};
    }
    const QString srcPath = source.isLocalFile() ? source.toLocalFile() : source.toString();
    if (srcPath.isEmpty() || !QFile::exists(srcPath)) {
        emit compressionFailed(QStringLiteral("Source not found: %1").arg(srcPath));
        return {};
    }

    const QString destPath = QStringLiteral("%1/%2.jpg").arg(localPhotosDir(), productId);
    QFile::remove(destPath);  // overwrite previous
    if (!QFile::copy(srcPath, destPath)) {
        emit compressionFailed(QStringLiteral("Cannot copy to local store"));
        return {};
    }
    return QUrl::fromLocalFile(destPath).toString();
}

bool ImageProcessor::removeLocalCopy(const QString &productId)
{
    if (productId.isEmpty()) return false;
    const QString destPath = QStringLiteral("%1/%2.jpg").arg(localPhotosDir(), productId);
    if (!QFile::exists(destPath)) return true;
    return QFile::remove(destPath);
}
