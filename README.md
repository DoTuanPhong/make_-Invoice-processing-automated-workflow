# Invoice Processing Automated Workflow

**Workflow ID:** `InfDUsLVIxCSqqlg`
**n8n:** http://127.0.0.1:5678
**Webhook:** `POST http://127.0.0.1:5678/webhook/invoice-incoming`

## Tổng quan

Workflow tự động xử lý hóa đơn: nhận hóa đơn → AI trích xuất dữ liệu → validate (kiểm tra field bắt buộc + kiểm tra toán học) → lưu Google Sheets → thông báo Slack → approval flow cho hóa đơn giá trị cao.

## Flow

1. **Invoice Webhook** — nhận hóa đơn qua POST
2. **AI Extract Invoice** — OpenAI gpt-4o-mini trích xuất JSON
3. **Validate & Format** — kiểm tra field bắt buộc + kiểm tra toán học (mathCheck)
4. **Log Invoice** — Google Sheets (14 cột, status = Pending)
5. **Notify Team** — Slack thông báo
6. **High Value?** — totalAmount > 1000?
   - **true** → Request Approval (Slack) → Wait for Approval → Update Invoice Status
   - **false** → Auto-Approve (Google Sheets → Approved)

## Files

| File | Mô tả |
|---|---|
| `activity-diagram.md` | UML Activity Diagram (có swimlane) |
| `sequence-diagram.md` | UML Sequence Diagram |
| `state-diagram.md` | UML State Machine Diagram |
| `invoice-processing-workflow.json` | n8n workflow JSON (export từ n8n) |

## Webhook API

**Request:**

```json
POST /webhook/invoice-incoming
{ "invoiceText": "<nội dung hóa đơn>", "fileName": "invoice.pdf" }
```

**AI Extract output:**

```json
{
  "vendor": "string",
  "billTo": "string",
  "invoiceNumber": "string",
  "invoiceDate": "YYYY-MM-DD",
  "dueDate": "YYYY-MM-DD",
  "poNumber": "string",
  "paymentTerms": "Net 30",
  "currency": "USD",
  "subtotal": 0,
  "taxRate": 0,
  "taxAmount": 0,
  "totalAmount": 0,
  "lineItems": [
    { "description": "string", "quantity": 0, "unitPrice": 0, "amount": 0 }
  ]
}
```

## Google Sheets columns (14)

Vendor · Bill To · Invoice Number · Invoice Date · Due Date · PO Number · Payment Terms · Currency · Subtotal · Tax Rate · Tax Amount · Total Amount · Math Check · Status

## Credentials cần tạo (n8n → Settings → Credentials)

| Credential | Type | Dùng cho node |
|---|---|---|
| OpenAI | API key | AI Extract Invoice |
| Google Sheets | OAuth | Log Invoice, Update Invoice Status, Auto-Approve |
| Slack | OAuth | Notify Team, Request Approval |

## Cấu hình cần điền

- **Google Sheets:** Spreadsheet ID + Sheet name (tên tab)
- **Slack:** channel (hiện để `#invoices`)

## Kiểm tra toán học (mathCheck)

```
calcSubtotal = Σ lineItems.amount
calcTotal    = subtotal + taxAmount
mathCheck    = OK nếu |calcTotal − totalAmount| < 0.05, ngược lại MISMATCH
```

→ MISMATCH flag hóa đơn cần review thủ công (tránh ghi sai dữ liệu khi AI đọc sai).
