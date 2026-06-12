#include "Clipboard.h"

#include <QClipboard>
#include <QGuiApplication>

Clipboard::Clipboard(QObject *parent)
    : QObject(parent)
{
}

void Clipboard::copy(const QString &text)
{
    if (QClipboard *cb = QGuiApplication::clipboard())
        cb->setText(text);
}
