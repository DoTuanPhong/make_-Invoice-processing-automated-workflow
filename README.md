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
   - **true** → Request Approval (Slack, includes `{{ $execution.resumeUrl }}`) → Wait for Approval (webhook) → Update Invoice Status
   - **false** → Auto-Approve (Google Sheets → Approved)

## Approval flow (high value)

1. **Request Approval** posts to Slack with the runtime resume URL (`{{ $execution.resumeUrl }}`) and the invoice number.
2. **Wait for Approval** pauses the execution (webhook URL generated at runtime).
3. Approver POSTs JSON to the resume URL:
   ```json
   { "invoiceNumber": "INV-123", "status": "Approved" }
   ```
   (or `"status": "Rejected"`)
4. **Update Invoice Status** finds the Google Sheets row by **Invoice Number** (`columns.matchingColumns`) and sets **Status** to `Approved` / `Rejected`.

> Alternative (n8n-native): replace Request Approval + Wait with a single Slack node using operation **Send and Wait for Response** (`sendAndWait`) — approver clicks a button in Slack and the response flows through automatically. Requires Slack OAuth2 with interactivity configured.

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
| Google Sheets | OAuth2 (hoặc Service Account) | Log Invoice, Update Invoice Status, Auto-Approve |
| Slack | OAuth2 (hoặc Access Token) | Notify Team, Request Approval |

## Cấu hình cần điền

- **Google Sheets:** Spreadsheet ID + Sheet name (tên tab) — hiện đang để trống ở 3 node Google Sheets (`documentId`, `sheetName`)
- **Slack:** channel (hiện để `#invoices`, mode=name)

## Còn lại để chạy được (cần user cung cấp)

1. Tạo 3 credentials ở trên trong n8n
2. Điền Spreadsheet ID + Sheet name vào Log Invoice / Update Invoice Status / Auto-Approve
3. Tạo sheet với 14 cột: Vendor · Bill To · Invoice Number · Invoice Date · Due Date · PO Number · Payment Terms · Currency · Subtotal · Tax Rate · Tax Amount · Total Amount · Math Check · Status
4. Activate workflow (hiện `active: false`) → webhook `POST /webhook/invoice-incoming` mới hoạt động
5. Test với sample invoice

## Đã sửa (lần này)

- AI Extract Invoice: `resource: chat`, `operation: complete`, `prompt.messages`, `simplifyOutput`, `maxTokens: 4096` (config cũ `chatMessage`/`jsonOutput` không tồn tại trong n8n 2.42.4)
- Validate & Format: đọc `item.message.content` (output đã simplify)
- Wait for Approval: `resume: webhook` (tham số đúng, cũ dùng `waitUntil` sai)
- Slack nodes: `select: channel`, `channelId: {mode: name, value: #invoices}` (resourceLocator, cũ dùng `channel` sai)
- Update Invoice Status / Auto-Approve: `columns.matchingColumns: ["Invoice Number"]` + giá trị match trong `columns.value` (bắt buộc với Google Sheets v4 update)
- Request Approval: message có kèm `{{ $execution.resumeUrl }}` + hướng dẫn approver POST `{invoiceNumber, status}`

## Kiểm tra toán học (mathCheck)

```
calcSubtotal = Σ lineItems.amount
calcTotal    = subtotal + taxAmount
mathCheck    = OK nếu |calcTotal − totalAmount| < 0.05, ngược lại MISMATCH
```

→ MISMATCH flag hóa đơn cần review thủ công (tránh ghi sai dữ liệu khi AI đọc sai).
