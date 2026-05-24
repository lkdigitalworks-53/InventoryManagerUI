#pragma once

#include <QObject>
#include <QString>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

// XlsxService — reads and writes the canonical Products / Orders workbooks
// for import-export. Workbook layout:
//   Sheet "Products" or "Orders" — header row + data rows
//   Sheet "README"               — schema documentation, allowed values
//   Sheet "Errors"               — appended after a failed import (optional)
//
// Designed to be called from QML; all methods accept/return Qt-native types
// so the QML side never touches QXlsx directly.
class XlsxService final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(XlsxService)

public:
    explicit XlsxService(QObject *parent = nullptr);
    ~XlsxService() override = default;

    // Write a Products workbook. `products` is a QVariantList of QVariantMaps,
    // each carrying the InventoryStore product schema. Returns the file URL,
    // empty on failure.
    Q_INVOKABLE QString writeProducts(const QVariantList &products,
                                      const QString &suggestedName = {});

    // Write an Orders workbook. `orders` line items are flattened into the
    // "Products" cell of each row using the SKU:qty:price syntax.
    Q_INVOKABLE QString writeOrders(const QVariantList &orders,
                                    const QString &suggestedName = {});

    Q_INVOKABLE QString writeStaff(const QVariantList &staff,
                                   const QString &suggestedName = {});

    // Read any workbook produced by the above. Returned map keys:
    //   "products": QVariantList of row maps (when a "Products" sheet exists)
    //   "orders":   QVariantList of row maps (when an "Orders" sheet exists)
    //   "errors":   QStringList of structural problems (missing sheets, etc.)
    Q_INVOKABLE QVariantMap readWorkbook(const QUrl &fileUrl);

    // Convenience accessor used by the README sheet writer; published so QML
    // can also reuse the canonical column lists for help text.
    Q_INVOKABLE QStringList productHeaders() const;
    Q_INVOKABLE QStringList orderHeaders() const;
    Q_INVOKABLE QStringList staffHeaders() const;

private:
    static QString outputDir();
    static QString stamp();
};
