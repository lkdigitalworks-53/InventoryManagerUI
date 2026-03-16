
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
using namespace Qt::StringLiterals;
int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [](){ QCoreApplication::exit(-1); }, Qt::QueuedConnection);
    engine.loadFromModule(u"BusinessApp"_qs, u"Main"_qs);
    return app.exec();
}
