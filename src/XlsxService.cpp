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

// Canonical order columns — one row per line item. Order-level columns repeat
// for each line of the same order so the sheet stays human-friendly. Orders
// with zero line items still emit a single row with empty product columns.
const QStringList kOrderHeaders = {
    "Order ID", "Customer", "Email", "Phone", "Status", "Date", "Notes",
    "Discount Type", "Discount Value", "Order Subtotal", "Order Discount",
    "Order Tax", "Order Total",
    "Product ID", "SKU", "Product Name", "Quantity", "Unit Price",
    "Tax %", "Line Tax", "Line Total"
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

void writeOrdersSheet(Document &doc, const QVariantList &orders)
{
    writeHeaderRow(doc, kOrderHeaders);

    int row = 2;
    for (int i = 0; i < orders.size(); ++i) {
        const QVariantMap o = orders.at(i).toMap();
        const QVariantList items = o.value("products").toList();

        const QString orderId = variantToString(o.value("orderId"));
        const QString customer = variantToString(o.value("customer"));
        const QString email = variantToString(o.value("email"));
        const QString phone = variantToString(o.value("phone"));
        const QString status = variantToString(o.value("status"));
        const QString date = variantToString(o.value("date"));
        const QString notes = variantToString(o.value("notes"));
        const QString discountType = variantToString(o.value("discountType"));
        const double discountValue = variantToNumber(o.value("discountValue"));
        const double subtotal = variantToNumber(o.value("subtotal"));
        const double discount = variantToNumber(o.value("discount"));
        const double tax = variantToNumber(o.value("tax"));
        const double total = variantToNumber(o.value("total"));

        auto writeOrderHeaderCols = [&](int r) {
            doc.write(r, 1,  orderId);
            doc.write(r, 2,  customer);
            doc.write(r, 3,  email);
            doc.write(r, 4,  phone);
            doc.write(r, 5,  status);
            doc.write(r, 6,  date);
            doc.write(r, 7,  notes);
            doc.write(r, 8,  discountType);
            doc.write(r, 9,  discountValue);
            doc.write(r, 10, subtotal);
            doc.write(r, 11, discount);
            doc.write(r, 12, tax);
            doc.write(r, 13, total);
        };

        if (items.isEmpty()) {
            writeOrderHeaderCols(row);
            ++row;
            continue;
        }

        for (const QVariant &it : items) {
            const QVariantMap line = it.toMap();
            writeOrderHeaderCols(row);

            const QString lineProductId = variantToString(line.value("productId"));
            // SKU isn't stored on the line item; the column stays for human
            // readability and downstream import resolves by Product ID.
            const QString sku;
            const int qty = static_cast<int>(variantToNumber(line.value("quantity")));
            const double unitPrice = variantToNumber(line.value("price"));
            const double taxPct = variantToNumber(line.value("taxPercent"));
            const bool taxable = line.value("taxable").toBool();
            const double lineGross = qty * unitPrice;
            const double lineTax = (taxable && taxPct > 0)
                ? (lineGross * (taxPct / 100.0))
                : 0.0;

            doc.write(row, 14, lineProductId);
            doc.write(row, 15, sku);
            doc.write(row, 16, variantToString(line.value("name")));
            doc.write(row, 17, qty);
            doc.write(row, 18, unitPrice);
            doc.write(row, 19, taxable ? taxPct : 0.0);
            doc.write(row, 20, lineTax);
            doc.write(row, 21, lineGross);

            ++row;
        }
    }

    doc.setColumnWidth(1, 12);   // Order ID
    doc.setColumnWidth(2, 24);   // Customer
    doc.setColumnWidth(3, 24);   // Email
    doc.setColumnWidth(4, 16);   // Phone
    doc.setColumnWidth(5, 14);   // Status
    doc.setColumnWidth(6, 12);   // Date
    doc.setColumnWidth(7, 28);   // Notes
    doc.setColumnWidth(8, 14);   // Discount Type
    doc.setColumnWidth(9, 14);   // Discount Value
    doc.setColumnWidth(10, 14);  // Order Subtotal
    doc.setColumnWidth(11, 14);  // Order Discount
    doc.setColumnWidth(12, 12);  // Order Tax
    doc.setColumnWidth(13, 14);  // Order Total
    doc.setColumnWidth(14, 12);  // Product ID
    doc.setColumnWidth(15, 14);  // SKU
    doc.setColumnWidth(16, 28);  // Product Name
    doc.setColumnWidth(17, 10);  // Quantity
    doc.setColumnWidth(18, 12);  // Unit Price
    doc.setColumnWidth(19, 8);   // Tax %
    doc.setColumnWidth(20, 12);  // Line Tax
    doc.setColumnWidth(21, 14);  // Line Total
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
            {"Order ID",        "no",  "text",   "Empty → auto-generated as ORD-NNN. Repeats on every line of the same order."},
            {"Customer *",      "yes", "text",   "Customer name. Repeats on every line of the same order."},
            {"Email",           "no",  "text",   "Repeats on every line of the same order."},
            {"Phone",           "no",  "text",   "Repeats on every line of the same order."},
            {"Status",          "no",  "text",   "One of: pending, processing, completed, out of stock. Default pending."},
            {"Date",            "no",  "date",   "yyyy-MM-dd preferred; dd/MM/yyyy and MM/dd/yyyy are accepted. Default today."},
            {"Notes",           "no",  "text",   ""},
            {"Discount Type",   "no",  "text",   "'flat' or 'percent'. Repeats on every line of the same order."},
            {"Discount Value",  "no",  "number", "Number applied to the order subtotal (flat ₹ or %)."},
            {"Order Subtotal",  "no",  "number", "Recomputed on import from line items × prices."},
            {"Order Discount",  "no",  "number", "Recomputed on import from Discount Type/Value."},
            {"Order Tax",       "no",  "number", "Recomputed on import from line tax %."},
            {"Order Total",     "no",  "number", "Recomputed on import: Subtotal − Discount + Tax."},
            {"Product ID",      "no",  "text",   "Inventory PRD-NNN if known. Otherwise SKU is used to resolve."},
            {"SKU",              "no",  "text",   "Inventory SKU. Used to resolve Product ID when blank."},
            {"Product Name",    "no",  "text",   "Display name; informational on import (resolved from inventory)."},
            {"Quantity",        "no",  "integer","Per-line quantity."},
            {"Unit Price",      "no",  "number", "Per-line selling price; defaults to inventory selling price."},
            {"Tax %",           "no",  "number", "Per-line tax rate; resolved from inventory if 0."},
            {"Line Tax",        "no",  "number", "Quantity × Unit Price × Tax%. Recomputed on import."},
            {"Line Total",      "no",  "number", "Quantity × Unit Price (gross). Recomputed on import."},
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

QString XlsxService::writeAnalysis(const QString &title,
                                   const QVariantList &sections,
                                   const QString &suggestedName)
{
    Document doc;
    doc.addSheet("Analysis");

    Format titleFmt;
    titleFmt.setFontBold(true);
    titleFmt.setFontSize(14);
    titleFmt.setFontColor(QColor("#1e3a8a"));

    Format sectionFmt;
    sectionFmt.setFontBold(true);
    sectionFmt.setFontSize(12);
    sectionFmt.setFontColor(QColor("#1e3a8a"));

    Format hdrFmt;
    hdrFmt.setFontBold(true);
    hdrFmt.setPatternBackgroundColor(QColor("#dbeafe"));
    hdrFmt.setBorderStyle(Format::BorderThin);

    int row = 1;
    if (!title.isEmpty()) {
        doc.write(row, 1, title, titleFmt);
        ++row;
        doc.write(row, 1, QDateTime::currentDateTime().toString(Qt::ISODate));
        ++row;
        ++row;  // blank gap before the first section
    }

    int widestColumnCount = 0;

    // Render each section as a heading + header row + data rows, separated
    // by one blank row.
    for (const QVariant &sv : sections) {
        const QVariantMap sec = sv.toMap();
        const QString heading = sec.value("heading").toString();
        const QStringList headers = sec.value("headers").toStringList();
        const QVariantList rows = sec.value("rows").toList();
        widestColumnCount = std::max(widestColumnCount, static_cast<int>(headers.size()));

        if (!heading.isEmpty()) {
            doc.write(row, 1, heading, sectionFmt);
            ++row;
        }

        for (int col = 0; col < headers.size(); ++col)
            doc.write(row, col + 1, headers.at(col), hdrFmt);
        ++row;

        for (const QVariant &rv : rows) {
            const QVariantList line = rv.toList();
            for (int col = 0; col < headers.size() && col < line.size(); ++col) {
                const QVariant cell = line.at(col);
                // Treat int / double / float as numeric; everything else is
                // stringified to preserve currency symbols and ISO dates.
                const int t = cell.typeId();
                if (t == QMetaType::Int || t == QMetaType::UInt
                    || t == QMetaType::Double || t == QMetaType::Float
                    || t == QMetaType::LongLong || t == QMetaType::ULongLong)
                    doc.write(row, col + 1, cell.toDouble());
                else
                    doc.write(row, col + 1, cell.toString());
            }
            ++row;
        }
        ++row;  // blank gap between sections
    }

    // Reasonable column widths — first column wider for label, rest moderate.
    if (widestColumnCount >= 1) doc.setColumnWidth(1, 24);
    for (int col = 2; col <= widestColumnCount; ++col)
        doc.setColumnWidth(col, 16);

    doc.selectSheet("Analysis");

    const QString name = suggestedName.isEmpty()
        ? QStringLiteral("analysis_%1.xlsx").arg(stamp())
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
