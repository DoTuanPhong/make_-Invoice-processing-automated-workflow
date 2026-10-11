# Invoice Processing Automated Workflow

**Workflow ID:** `InfDUsLVIxCSqqlg`
**n8n:** http://127.0.0.1:5678
**Webhook:** `POST http://127.0.0.1:5678/webhook/invoice-incoming` (**bat buoc** header `x-invoice-key: <key>`)

## Tổng quan

Workflow tự động xử lý hóa đơn: nhận hóa đơn → AI trích xuất dữ liệu → validate (kiểm tra field bắt buộc + kiểm tra toán học) → lưu Google Sheets → thông báo Slack → approval flow cho hóa đơn giá trị cao.

## Trạng thái: ĐÃ TEST END-TO-END ✅

Workflow `Invoice Processing Automated` đã **chạy thành công toàn bộ luồng** (ngày 2026-10-10):

```
Webhook → AI Extract (Gemini) → Validate → Sheets append → Slack notify
       → Needs review? → true: Request Approval → Wait → POST approval → Update Status (Approved/Rejected)
                    → false: Auto-Approve
```

Kết quả test: invoice cao (6050 > 1000) → gửi approval → POST `{invoiceNumber, status: "Rejected"}` → execution **success** → Sheets row cập nhật **Rejected** ✅

## Các lỗi đã fix trong quá trình test

| Lỗi | Nguyên nhân | Fix |
|---|---|---|
| AI Extract lỗi 404 | `gemini-2.5-flash` không khả dụng cho account mới | đổi sang `gemini-3.5-flash-lite` |
| Validate "Missing required fields" | jsonBody dùng `{{ }}` không được evaluate | dùng `={{ JSON.stringify({...}) }}` |
| Slack message toàn "undefined" | Log Invoice (Sheets append) trả API response, **thay thế data chain** | restructure: Validate & Format fan-out → Log Invoice / Notify Team / High Value? |
| High Value? luôn rẽ false | operator `larger` sai → đúng phải là `gt` | sửa operation + thêm `options.version: 1` |
| Approval POST 404 "no matching path/method" | Wait node `httpMethod` mặc định GET | set `httpMethod: "POST"` |
| Update Status không cập nhật row | sau Wait resume, data nested trong `body` ($json.body.invoiceNumber) | expression `$json.body.X \|\| $json.X` |

1. **Invoice Webhook** — nhận hóa đơn qua POST
2. **AI Extract Invoice** — Google Gemini 3.5-flash-lite (HTTP Request node, JSON mode)
3. **Validate & Format** — kiểm tra field bắt buộc + kiểm tra toán học (mathCheck)
4. **Log Invoice** — Google Sheets (14 cột, status = Pending)
5. **Notify Team** — Slack thông báo
6. **Needs review?** — `totalAmount > 1000` **HOặC** `mathCheck != OK`?
   → Hóa đơn lệch số học (`MISMATCH`) KHÔNG tự động duyệt — ghi sổ với `Status = Needs Review` và luôn đi nhánh chờ người duyệt.
   - **true** → Request Approval (Slack, includes `{{ $execution.resumeUrl }}`) → Wait for Approval (webhook) → Update Invoice Status
   - **false** → Auto-Approve (Google Sheets → Approved)

## Approval flow (hóa đơn cao giá trị HOẶC lệch số học)

1. **Request Approval** posts to Slack with the runtime resume URL (`{{ $execution.resumeUrl }}`) and the invoice number.
2. **Wait for Approval** pauses the execution (webhook URL generated at runtime).
3. Approver POSTs JSON to the resume URL (can co **`dedupKey`** — n8n match row bang key nay):
   ```json
   {
     "dedupKey": "GLOBAL TECH SERVICES LTD|INV-123",
     "status": "Approved",
     "approvedBy": "ten hoac email",
     "comment": "ly do (tuy chon)"
   }
   ```
4. **Update Invoice Status** tim row bang **Dedup Key** (`columns.matchingColumns`) va set **Status** thanh `Approved` / `Rejected`.

   > `dedupKey` duoc In ra trong message Slack cua buoc Request Approval — approver chi can copy lai.

> Alternative (n8n-native): replace Request Approval + Wait with a single Slack node using operation **Send and Wait for Response** (`sendAndWait`) — approver clicks a button in Slack and the response flows through automatically. Requires Slack OAuth2 with interactivity configured.

## Files

| File | Mô tả |
|---|---|
| `activity-diagram.md` | UML Activity Diagram (có swimlane) |
| `sequence-diagram.md` | UML Sequence Diagram |
| `state-diagram.md` | UML State Machine Diagram |
| `BUSINESS-SPEC.md` | **Đặc tả nghiệp vụ đầy đủ** (16 phần, đánh dấu đã có / dự kiến) |
| `SETUP.md` | Hướng dẫn setup từ đầy đầy (bố cục, troubleshooting) |
| `invoice-processing-workflow.json` | n8n workflow JSON (export/import) |
| `error-handler-workflow.json` | Error handler v2 — JSON để import |
| `error-handler-v1-archived.json` | Bản lưu error handler v1 (chỉ post Slack) để hoàn tác |

## Webhook API

**Request:**

```bash
curl -X POST http://127.0.0.1:5678/webhook/invoice-incoming \
  -H "Content-Type: application/json" \
  -H "x-invoice-key: <key lay trong n8n > Credentials > Invoice Webhook Key>" \
  -d '{"invoiceText":"<nội dung hóa đơn>","fileName":"invoice.pdf"}'
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

## Google Sheets: 2 tab

**`Sheet1`** (15 cột): Vendor · Bill To · Invoice Number · Invoice Date · Due Date · PO Number · Payment Terms · Currency · Subtotal · Tax Rate · Tax Amount · Total Amount · Math Check · Status · Dedup Key

**`Exceptions`** (13 cột): Exception ID · Timestamp · Execution ID · Failed Node · Category · Severity · Error Message · Execution URL · Retry Of · Mode · Status · Resolution · Notes

## Credentials cần tạo (n8n → Settings → Credentials)

| Credential | Type | Dùng cho node |
|---|---|---|
| Google Gemini API | HttpQueryAuth (query param `key` = API key, lấy free tại aistudio.google.com) | AI Extract Invoice |
| Google Sheets | OAuth2 (hoặc Service Account) | Log Invoice, Update Invoice Status, Auto-Approve |
| Slack | OAuth2 (hoặc Access Token) | Notify Team, Request Approval |

## Cấu hình đã hoàn thành

| Hạng | Giá trị |
|---|---|
| Credentials | 4/4 đã tạo (Gemini `httpQueryAuth`, Google Sheets `googleApi`, Slack `slackApi`, Webhook `httpHeaderAuth`) |
| Google Sheets | Spreadsheet ID + Sheet name đã điền, 14 cột, đã share Editor cho service account |
| Slack | channel `#all-n8nreceipt` (dùng `chat:write.public`, không cần invite bot) |
| Webhook auth | header `x-invoice-key` (credential **Invoice Webhook Key**) — không có header sẽ trả 403 |
| `Log Invoice` | `appendOrUpdate` (upsert) theo **Dedup Key** — gửi lại cùng hóa đơn không tạo dòng trùng |
| `Wait for Approval` | chối tối đa **7 ngày** (`limitWaitTime`) |
| Workflow | **active** — webhook `POST /webhook/invoice-incoming` đang hoạt động |
| Error Handler | **Invoice Error Handler v2** (active, link `settings.errorWorkflow`): phân loại lỗi → ghi DLQ tab `Exceptions` → Slack |

Để setup lại từ đầu trên môi trường khác → xem **[SETUP.md](SETUP.md)**.

## Đã sửa (lần này)

- AI Extract Invoice: đổi từ OpenAI sang **Google Gemini 3.5-flash-lite** qua **HTTP Request node** (v4.5): `method: POST`, `url: .../models/gemini-3.5-flash-lite:generateContent`, `authentication: genericCredentialType`, `genericAuthType: httpQueryAuth`, `jsonBody` gồm `systemInstruction` + `contents` + `generationConfig.responseMimeType: application/json`. API key truyền qua credential HttpQueryAuth (query param `key`) — free tier tại aistudio.google.com
- Validate & Format: đọc `item.candidates[0].content.parts[0].text` (Gemini response), fallback OpenAI formats
- Wait for Approval: `resume: webhook` (tham số đúng, cũ dùng `waitUntil` sai)
- Slack nodes: `select: channel`, `channelId: {mode: name, value: #invoices}` (resourceLocator, cũ dùng `channel` sai)
- Update Invoice Status / Auto-Approve: `columns.matchingColumns: ["Invoice Number"]` + giá trị match trong `columns.value` (bắt buộc với Google Sheets v4 update)
- Request Approval: message có kèm `{{ $execution.resumeUrl }}` + hướng dẫn approver POST `{invoiceNumber, status}`
- Error handling: **Invoice Error Handler v2** (Error Trigger → Code phân loại → Sheets append DLQ → Slack). Phân loại 16 loại lỗi thành 5 nhóm: `data/validation`, `infra/permission`, `Google API`, `Slack/integration`, `transient (API)`, `unknown` — kèm severity + route (IT vs AP Clerk). Đã verify end-to-end: lỗi cố ý → exec error → DLQ ghi dòng → Slack nhận đúng (`:warning:`, route AP Clerk)

## Kiểm tra toán học (mathCheck)

```
calcSubtotal = Σ lineItems.amount
calcTotal    = subtotal + taxAmount
mathCheck    = OK nếu |calcTotal − totalAmount| < 0.05, ngược lại MISMATCH
```

→ MISMATCH flag hóa đơn cần review thủ công (tránh ghi sai dữ liệu khi AI đọc sai).

## Quy tắc validate (hardening 2026-10-11)

Node `Validate & Format` **từ chối** (throwing → error workflow) khi:

| Điều kiện | Ví dụ bị chặn |
|---|---|
| Thiếu field bắt buộc | `vendor` / `billTo` / `invoiceNumber` rỗng |
| Field là object/array thay vì text | `vendor: ["ACME"]` |
| `totalAmount` không parse được thành số | `"N/A"`, `{value:500}` |
| `totalAmount <= 0` | `0`, `(500.00)` (= -500) |
| `currency` không phải ISO 3 chữ | `840`, `"us dollar"` |
| `lineItems` có nhưng không phải array | `"nope"` |

Parse số an toàn: `"12,500.00"` → 12500, `"12.500,00"` → 12500, `"USD 1250.00"` → 1250, `"(500)"` → -500.

> ⚠️ **Giạn hạn:** với dạng 3 chữ số sau dấu phây (`500.000`) code chọn cách đọc theo chuẩn châu Âu (500.000). Nếu vendor dùng dạng US với 3 chữ số thập phân, số sẽ bị đọc lại — hãy đối chiếu bằng `mathCheck` khi xử lý hóa đơn từ vendor như vậy.
