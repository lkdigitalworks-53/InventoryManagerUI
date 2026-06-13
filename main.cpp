#include <QApplication>
#include <FelgoApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include "src/OAuthServer.h"
#include "src/ImageProcessor.h"
#include "src/XlsxService.h"
#include "src/NativeFile.h"
#include "src/Clipboard.h"
#include "src/PkceGenerator.h"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    FelgoApplication felgo;

    QQmlApplicationEngine engine;
    felgo.initialize(&engine);

    // Register local OAuth callback server as a QML singleton context property.
    auto *oauthServer = new OAuthServer(&app);
    engine.rootContext()->setContextProperty(QStringLiteral("OAuthServer"), oauthServer);

    // Register image compression helper (used by the photo picker pipeline).
    auto *imageProcessor = new ImageProcessor(&app);
    engine.rootContext()->setContextProperty(QStringLiteral("ImageProcessor"), imageProcessor);

    // Register XLSX read/write helper (used by the import/export pipeline).
    auto *xlsxService = new XlsxService(&app);
    engine.rootContext()->setContextProperty(QStringLiteral("XlsxService"), xlsxService);

    // Register the content-URI → readable-path helper (photo + import pickers).
    auto *nativeFile = new NativeFile(&app);
    engine.rootContext()->setContextProperty(QStringLiteral("NativeFile"), nativeFile);

    // Register the clipboard helper (copy User ID, etc.).
    auto *clipboard = new Clipboard(&app);
    engine.rootContext()->setContextProperty(QStringLiteral("Clipboard"), clipboard);

    // Register the PKCE helper (native Google auth-code flow on mobile).
    auto *pkceGenerator = new PkceGenerator(&app);
    engine.rootContext()->setContextProperty(QStringLiteral("PkceGenerator"), pkceGenerator);

    // Set an optional license key from project file
    felgo.setLicenseKey(PRODUCT_LICENSE_KEY);

    // use this during development
    // for PUBLISHING, use the entry point below
    felgo.setMainQmlFileName(QStringLiteral("qml/Main.qml"));

    // use this instead of the above call to avoid deployment of the qml files
    // and compile them into the binary with qt's resource system qrc
    // this is the preferred deployment option for publishing apps to the app stores
    //felgo.setMainQmlFileName(QStringLiteral("qrc:/qml/Main.qml"));

    engine.load(QUrl(felgo.mainQmlFileName()));

    return app.exec();
}
