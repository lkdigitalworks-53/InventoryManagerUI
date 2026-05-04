
#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
using namespace Qt::StringLiterals;
int main(int argc, char *argv[]) {
    QQuickStyle::setStyle(u"Basic"_s);
    QApplication app(argc, argv);
    app.setOrganizationName(u"BusinessApp"_s);
    app.setApplicationName(u"BusinessManagement"_s);
    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [](){ QCoreApplication::exit(-1); }, Qt::QueuedConnection);
    engine.loadFromModule(u"BusinessApp"_s, u"Main"_s);
    return app.exec();
}
