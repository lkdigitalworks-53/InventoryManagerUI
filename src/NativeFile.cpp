#include "NativeFile.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

NativeFile::NativeFile(QObject *parent)
    : QObject(parent)
{
}

QString NativeFile::cacheDir()
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    QDir().mkpath(base);
    return base;
}

QString NativeFile::toReadablePath(const QUrl &uri)
{
    // Already a local file (file:// URL or a path that parsed as local) → use as-is.
    if (uri.isLocalFile()) {
        const QString local = uri.toLocalFile();
        return QFile::exists(local) ? local : QString();
    }

    const QString asString = uri.toString();
    const QString scheme = uri.scheme();

    // A raw filesystem path that QUrl mis-parsed → treat as a local path:
    //   • empty scheme  → a bare relative/absolute path
    //   • 1-char scheme → a Windows drive letter, e.g. "C:/dir/file.xlsx" parses
    //     with scheme "c". This is the common desktop file-picker result and
    //     must NOT be sent down the content-copy branch (which would fail).
    if (scheme.isEmpty() || scheme.length() == 1) {
        return QFile::exists(asString) ? asString : QString();
    }

    // Defensive: any other string that happens to name an existing local file.
    if (QFile::exists(asString))
        return asString;

    // content:// (Android) and any other non-local scheme Qt can open: copy the
    // bytes into the cache. Qt's Android backend maps content:// through the
    // ContentResolver, so QFile can read it directly.
    QFile in(asString);
    if (!in.open(QIODevice::ReadOnly))
        return {};

    // Preserve a sensible extension so downstream readers (image / xlsx) sniff
    // the type correctly. Fall back to .bin when none is present.
    QString suffix = QFileInfo(uri.path()).suffix();
    if (suffix.isEmpty())
        suffix = QStringLiteral("bin");

    const QString outPath = QStringLiteral("%1/picked_%2.%3")
        .arg(cacheDir())
        .arg(QString::number(QDateTime::currentMSecsSinceEpoch()))
        .arg(suffix);

    QFile out(outPath);
    if (!out.open(QIODevice::WriteOnly)) {
        in.close();
        return {};
    }

    // Stream-copy in chunks so large files don't spike memory.
    constexpr qint64 kChunk = 64 * 1024;
    while (!in.atEnd()) {
        const QByteArray buf = in.read(kChunk);
        if (buf.isEmpty()) break;
        if (out.write(buf) != buf.size()) {
            in.close();
            out.close();
            QFile::remove(outPath);
            return {};
        }
    }
    in.close();
    out.close();
    return outPath;
}
