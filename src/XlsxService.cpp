#include "XlsxService.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QStandardPaths>

#include "xlsxdocument.h"
#include "xlsxformat.h"

using QXlsx::Document;
using QXlsx::Format;

namespace {

// Canonical product columns, in the order they're written and expected on
// import. Keep in sync with the InventoryStore schema.
const QStringList kProductHeaders = {
    "Product ID", "Name", "SKU", "Category", "Unit", "Description",
    "Cost Price", "Selling Price", "Stock", "Min Stock", "Photo URL"
};

// Canonical order columns. "Products" cell uses pipe-separated SKU:qty[:price].
const QStringList kOrderHeaders = {
    "Order ID", "Customer", "Email", "Phone", "Status", "Date",
    "Items", "Total", "Notes", "Products"
};

// Canonical staff columns.
const QStringList kStaffHeaders = {
    "Staff ID", "Name", "Email", "Phone", "Role", "Department",
    "Join Date", "Status", "Salary"
};

QString variantToString(const QVariant &v)
{
    if (!v.isValid() || v.isNull()) return {};
    return v.toString();
}

double variantToNumber(const QVariant &v)
{
    if (!v.isValid() || v.isNull()) return 0.0;
    bool ok = false;
    const double d = v.toDouble(&ok);
    return ok ? d : 0.0;
}

void writeHeaderRow(Document &doc, const QStringList &headers)
{
    Format hdr;
    hdr.setFontBold(true);
    hdr.setPatternBackgroundColor(QColor("#dbeafe"));
    hdr.setBorderStyle(Format::BorderThin);
    for (int col = 0; col < headers.size(); ++col)
        doc.write(1, col + 1, headers.at(col), hdr);
}

void writeProductsSheet(Document &doc, const QVariantList &products)
{
    writeHeaderRow(doc, kProductHeaders);

    for (int i = 0; i < products.size(); ++i) {
        const QVariantMap p = products.at(i).toMap();
        const int row = i + 2;
        doc.write(row, 1,  variantToString(p.value("productId")));
        doc.write(row, 2,  variantToString(p.value("name")));
        doc.write(row, 3,  variantToString(p.value("sku")));
        doc.write(row, 4,  variantToString(p.value("category")));
        doc.write(row, 5,  variantToString(p.value("unit")));
        doc.write(row, 6,  variantToString(p.value("description")));
        doc.write(row, 7,  variantToNumber(p.value("price")));
        doc.write(row, 8,  variantToNumber(p.value("sellingPrice")));
        doc.write(row, 9,  static_cast<int>(variantToNumber(p.value("stock"))));
        doc.write(row, 10, static_cast<int>(variantToNumber(p.value("minStock"))));
        doc.write(row, 11, variantToString(p.value("photoUrl")));
    }

    // Reasonable column widths
    doc.setColumnWidth(1, 14);
    doc.setColumnWidth(2, 28);
    doc.setColumnWidth(3, 16);
    doc.setColumnWidth(4, 14);
    doc.setColumnWidth(5, 12);
    doc.setColumnWidth(6, 32);
    doc.setColumnWidth(7, 12);
    doc.setColumnWidth(8, 14);
    doc.setColumnWidth(9, 10);
    doc.setColumnWidth(10, 12);
    doc.setColumnWidth(11, 32);
}

QString flattenOrderProducts(const QVariantList &items)
{
    QStringList parts;
    for (const QVariant &item : items) {
        const QVariantMap m = item.toMap();
        const QString sku = variantToString(m.value("sku"));
        const QString name = variantToString(m.value("name"));
        const QString id = variantToString(m.value("productId"));
        const QString tag = !sku.isEmpty() ? sku : (!id.isEmpty() ? id : name);
        const int qty = static_cast<int>(variantToNumber(m.value("quantity")));
        const double price = variantToNumber(m.value("price"));
        parts << QStringLiteral("%1:%2:%3").arg(tag).arg(qty).arg(price);
    }
    return parts.join(" | ");
}

void writeOrdersSheet(Document &doc, const QVariantList &orders)
{
    writeHeaderRow(doc, kOrderHeaders);

    for (int i = 0; i < orders.size(); ++i) {
        const QVariantMap o = orders.at(i).toMap();
        const int row = i + 2;
        doc.write(row, 1,  variantToString(o.value("orderId")));
        doc.write(row, 2,  variantToString(o.value("customer")));
        doc.write(row, 3,  variantToString(o.value("email")));
        doc.write(row, 4,  variantToString(o.value("phone")));
        doc.write(row, 5,  variantToString(o.value("status")));
        doc.write(row, 6,  variantToString(o.value("date")));
        doc.write(row, 7,  static_cast<int>(variantToNumber(o.value("items"))));
        doc.write(row, 8,  variantToNumber(o.value("total")));
        doc.write(row, 9,  variantToString(o.value("notes")));
        doc.write(row, 10, flattenOrderProducts(o.value("products").toList()));
    }

    doc.setColumnWidth(1, 12);
    doc.setColumnWidth(2, 24);
    doc.setColumnWidth(3, 24);
    doc.setColumnWidth(4, 16);
    doc.setColumnWidth(5, 14);
    doc.setColumnWidth(6, 12);
    doc.setColumnWidth(7, 8);
    doc.setColumnWidth(8, 12);
    doc.setColumnWidth(9, 28);
    doc.setColumnWidth(10, 48);
}

void writeReadmeSheet(Document &doc, const QString &kind)
{
    Format title;
    title.setFontBold(true);
    title.setFontSize(14);
    title.setFontColor(QColor("#1e3a8a"));

    Format hdr;
    hdr.setFontBold(true);
    hdr.setPatternBackgroundColor(QColor("#dbeafe"));

    Format wrap;
    wrap.setTextWrap(true);

    int row = 1;
    doc.write(row++, 1, kind == "products" ? QStringLiteral("Products import/export — schema")
                                            : QStringLiteral("Orders import/export — schema"), title);
    doc.write(row++, 1, QStringLiteral("Edit the data sheet, then import this file back into the app. "
                                        "Empty cells use sensible defaults; required fields are marked with an asterisk."), wrap);
    row++;

    doc.write(row, 1, QStringLiteral("Column"), hdr);
    doc.write(row, 2, QStringLiteral("Required?"), hdr);
    doc.write(row, 3, QStringLiteral("Type"), hdr);
    doc.write(row, 4, QStringLiteral("Notes"), hdr);
    row++;

    if (kind == "products") {
        struct R { const char *col; const char *req; const char *type; const char *notes; };
        const R rows[] = {
            {"Product ID",    "no",  "text",   "Empty → auto-generated as PRD-NNN. If filled, must be unique."},
            {"Name *",        "yes", "text",   "Minimum 2 characters."},
            {"SKU",           "no",  "text",   "Empty → auto-generated. Used by the Orders sheet to reference products."},
            {"Category",      "no",  "text",   "Falls back to your last-used category. New values are added to the workspace list."},
            {"Unit",          "no",  "text",   "Default \"Units (pcs)\". Common values: Units (pcs), Kg, Litres, Metres."},
            {"Description",   "no",  "text",   "Free text."},
            {"Cost Price",    "no",  "number", "What you pay your supplier. Defaults to 0."},
            {"Selling Price *","yes","number", "What customers pay. Must be > 0 and ≥ Cost Price."},
            {"Stock",         "no",  "integer","Current stock on hand. Defaults to 0."},
            {"Min Stock",     "no",  "integer","Reorder threshold. Defaults to 0."},
            {"Photo URL",     "no",  "text",   "Public image URL. Leave empty to keep the existing photo."},
        };
        for (const R &r : rows) {
            doc.write(row, 1, QString::fromUtf8(r.col));
            doc.write(row, 2, QString::fromUtf8(r.req));
            doc.write(row, 3, QString::fromUtf8(r.type));
            doc.write(row, 4, QString::fromUtf8(r.notes), wrap);
            ++row;
        }
    } else {
        struct R { const char *col; const char *req; const char *type; const char *notes; };
        const R rows[] = {
            {"Order ID",      "no",  "text",   "Empty → auto-generated as ORD-NNN."},
            {"Customer *",    "yes", "text",   "Customer name."},
            {"Email",         "no",  "text",   ""},
            {"Phone",         "no",  "text",   ""},
            {"Status",        "no",  "text",   "One of: pending, processing, completed, out of stock. Default pending."},
            {"Date",          "no",  "date",   "yyyy-MM-dd preferred; dd/MM/yyyy and MM/dd/yyyy are accepted. Default today."},
            {"Items",         "no",  "integer","Recomputed from line items; cell value is ignored on import."},
            {"Total",         "no",  "number", "Recomputed from line items × prices."},
            {"Notes",         "no",  "text",   ""},
            {"Products",      "no",  "text",   "Pipe-separated lines of SKU:qty[:unit_price]. Example: ELE-2025-001:2 | ACC-2025-003:1:99.50"},
        };
        for (const R &r : rows) {
            doc.write(row, 1, QString::fromUtf8(r.col));
            doc.write(row, 2, QString::fromUtf8(r.req));
            doc.write(row, 3, QString::fromUtf8(r.type));
            doc.write(row, 4, QString::fromUtf8(r.notes), wrap);
            ++row;
        }
    }

    doc.setColumnWidth(1, 18);
    doc.setColumnWidth(2, 12);
    doc.setColumnWidth(3, 10);
    doc.setColumnWidth(4, 64);
}

QVariantList readSheet(Document &doc, const QString &sheetName, const QStringList &headers)
{
    if (!doc.selectSheet(sheetName))
        return {};

    QVariantList out;
    int row = 2;
    while (true) {
        // Sheet ends when the first cell of the row is empty AND no other cell has data.
        bool rowHasData = false;
        QVariantMap rec;
        for (int col = 0; col < headers.size(); ++col) {
            const QVariant cell = doc.read(row, col + 1);
            if (cell.isValid() && !cell.toString().isEmpty()) rowHasData = true;
            rec.insert(headers.at(col), cell);
        }
        if (!rowHasData) break;
        out.append(rec);
        ++row;
        if (row > 100000) break;  // hard safety cap
    }
    return out;
}

} // namespace

XlsxService::XlsxService(QObject *parent)
    : QObject(parent)
{
}

QString XlsxService::outputDir()
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    if (base.isEmpty())
        base = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    QDir().mkpath(base);
    return base;
}

QString XlsxService::stamp()
{
    return QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
}

QStringList XlsxService::productHeaders() const { return kProductHeaders; }
QStringList XlsxService::orderHeaders()   const { return kOrderHeaders; }
QStringList XlsxService::staffHeaders()   const { return kStaffHeaders; }

QString XlsxService::writeProducts(const QVariantList &products, const QString &suggestedName)
{
    Document doc;
    doc.addSheet("Products");
    writeProductsSheet(doc, products);

    doc.addSheet("README");
    writeReadmeSheet(doc, "products");

    doc.selectSheet("Products");

    const QString name = suggestedName.isEmpty()
        ? QStringLiteral("products_%1.xlsx").arg(stamp())
        : suggestedName;
    const QString path = QStringLiteral("%1/%2").arg(outputDir(), name);

    if (!doc.saveAs(path))
        return {};
    return QUrl::fromLocalFile(path).toString();
}

QString XlsxService::writeOrders(const QVariantList &orders, const QString &suggestedName)
{
    Document doc;
    doc.addSheet("Orders");
    writeOrdersSheet(doc, orders);

    doc.addSheet("README");
    writeReadmeSheet(doc, "orders");

    doc.selectSheet("Orders");

    const QString name = suggestedName.isEmpty()
        ? QStringLiteral("orders_%1.xlsx").arg(stamp())
        : suggestedName;
    const QString path = QStringLiteral("%1/%2").arg(outputDir(), name);

    if (!doc.saveAs(path))
        return {};
    return QUrl::fromLocalFile(path).toString();
}

QString XlsxService::writeStaff(const QVariantList &staff, const QString &suggestedName)
{
    Document doc;
    doc.addSheet("Staff");

    // Header
    Format hdr;
    hdr.setFontBold(true);
    hdr.setPatternBackgroundColor(QColor("#dbeafe"));
    hdr.setBorderStyle(Format::BorderThin);
    for (int col = 0; col < kStaffHeaders.size(); ++col)
        doc.write(1, col + 1, kStaffHeaders.at(col), hdr);

    for (int i = 0; i < staff.size(); ++i) {
        const QVariantMap s = staff.at(i).toMap();
        const int row = i + 2;
        doc.write(row, 1, variantToString(s.value("staffId")));
        doc.write(row, 2, variantToString(s.value("name")));
        doc.write(row, 3, variantToString(s.value("email")));
        doc.write(row, 4, variantToString(s.value("phone")));
        doc.write(row, 5, variantToString(s.value("role")));
        doc.write(row, 6, variantToString(s.value("department")));
        doc.write(row, 7, variantToString(s.value("joinDate")));
        doc.write(row, 8, variantToString(s.value("status")));
        doc.write(row, 9, variantToNumber(s.value("salary")));
    }

    doc.setColumnWidth(1, 12);
    doc.setColumnWidth(2, 24);
    doc.setColumnWidth(3, 26);
    doc.setColumnWidth(4, 16);
    doc.setColumnWidth(5, 18);
    doc.setColumnWidth(6, 18);
    doc.setColumnWidth(7, 14);
    doc.setColumnWidth(8, 12);
    doc.setColumnWidth(9, 12);

    doc.selectSheet("Staff");

    const QString name = suggestedName.isEmpty()
        ? QStringLiteral("staff_%1.xlsx").arg(stamp())
        : suggestedName;
    const QString path = QStringLiteral("%1/%2").arg(outputDir(), name);

    if (!doc.saveAs(path))
        return {};
    return QUrl::fromLocalFile(path).toString();
}

QVariantMap XlsxService::readWorkbook(const QUrl &fileUrl)
{
    QVariantMap result;
    QStringList errors;

    const QString path = fileUrl.isLocalFile() ? fileUrl.toLocalFile() : fileUrl.toString();
    if (path.isEmpty() || !QFile::exists(path)) {
        errors << QStringLiteral("File not found: %1").arg(path);
        result.insert("errors", errors);
        return result;
    }

    Document doc(path);
    if (!doc.load()) {
        errors << QStringLiteral("Could not open as XLSX: %1").arg(path);
        result.insert("errors", errors);
        return result;
    }

    const QStringList sheets = doc.sheetNames();
    if (sheets.contains("Products"))
        result.insert("products", readSheet(doc, "Products", kProductHeaders));
    if (sheets.contains("Orders"))
        result.insert("orders", readSheet(doc, "Orders", kOrderHeaders));

    if (!result.contains("products") && !result.contains("orders"))
        errors << QStringLiteral("No 'Products' or 'Orders' sheet found.");

    result.insert("errors", errors);
    return result;
}
