# QML Pages Documentation Checklist

Use this checklist with `@qt-qml-docs` to keep page and dialog docs complete.

## How To Use

1. Pick one unchecked file.
2. Prompt Copilot with `@qt-qml-docs` for that file.
3. Confirm output includes properties, signals, methods, and interactions.
4. Mark the item complete.
5. After all files are done, generate/update `qml/pages/doc/index.md`.

## Suggested Prompt Template

```text
Use @qt-qml-docs to generate Markdown reference documentation for the following component:
- qml/pages/<FILE_NAME>.qml
Place output under qml/pages/doc/ and keep sections aligned with the Qt QML docs skill.
```

## Component Coverage

- [ ] `qml/pages/OrdersPage.qml`
- [ ] `qml/pages/InventoryPage.qml`
- [ ] `qml/pages/SalesPage.qml`
- [ ] `qml/pages/StaffPage.qml`
- [ ] `qml/pages/NewOrderDialog.qml`
- [ ] `qml/pages/OrderDetailDialog.qml`
- [ ] `qml/pages/AddProductDialog.qml`
- [ ] `qml/pages/AddStaffDialog.qml`
- [ ] `qml/pages/RestockDialog.qml`

## Finalization

- [ ] `qml/pages/doc/index.md` exists and links all generated page/dialog docs
- [ ] All docs reviewed for current signal names in `qml/logic/Logic.qml`
- [ ] All docs reviewed for current data flow in `qml/model/DataModel.qml`
