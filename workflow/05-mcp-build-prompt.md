# Prompt tạo scenarios qua Make MCP

> Cách dùng: kết nối Make MCP server vào Cursor/Claude (xem `mcp/MAKE-MCP-SETUP.md`), mở chat mới, dán toàn bộ nội dung file này. AI sẽ dùng Make MCP management tools để tự tạo 2 scenarios.
> Yêu cầu: Make **paid plan** (management tools). Plan Free → build thủ công theo `01-workflow-design.md`.

---

Bạn đang kết nối Make MCP server. Hãy tạo **2 scenarios** trong Make org của tôi theo spec dưới đây.

## Yêu cầu chung

1. Cả 2 scenario đều **Active**. Scenario 1 scheduling **On demand**; Scenario 2 là webhook trigger (Immediately as data arrives).
2. Dùng các connection đã có trong org cho các app: Webhooks, OpenAI, Google Sheets, Google Drive, Slack, Email. Nếu app chưa có connection, tạo mới và hướng dẫn tôi authorize.
3. Bật error handling cho mỗi module (On error → nối vào error path).
4. Bật "Process data in order" trong settings cả 2 scenario.
5. Tạo trước Google Sheets spreadsheet tên `Invoice Ledger` với 2 sheets `Invoices` và `Exceptions` (cột như spec), và Google Drive folder `Invoices`.

## SCENARIO 1: "Invoice Processing"

### Scenario inputs (khai báo trong Scenario inputs)
- `invoice_json` — Text — JSON string chứa dữ liệu invoice (schema bên dưới)
- `file_url` — Text — URL file PDF/image invoice
- `auto_approve_threshold` — Number — default 5000000
- `notify_channel` — Text — default "#finance"

### Scenario outputs (khai báo trong Scenario outputs)
- `status` — Text — success | pending | exception | duplicate | error
- `invoice_id` — Text
- `vendor_name` — Text
- `total_amount` — Number
- `currency` — Text
- `approval_required` — Boolean
- `approval_decision` — Text — not_required | pending | approved | rejected
- `ledger_row_url` — Text
- `file_archive_url` — Text
- `message` — Text

### Mô tả scenario (Diagram → Options → Edit description)
"Xử lý invoice tự động: nhận invoice qua webhook hoặc MCP input, trích xuất dữ liệu bằng AI, kiểm tra trùng/lỗi, phê duyệt nếu vượt ngưỡng, ghi sổ cái Google Sheets, lưu PDF Google Drive, thông báo Slack. Trả về status, invoice_id, vendor, total."

### Flow (module theo thứ tự)

1. **Webhooks > Custom webhook** — trigger, tên "Invoice Intake". Định nghĩa data structure theo schema bên dưới (Advanced settings > Data structure).
2. **OpenAI > Create a chat completion** — model gpt-4o. System prompt: "Bạn là assistant trích xuất dữ liệu hóa đơn. Trả về MỘT object JSON duy nhất với các keys: invoice_number, vendor_name, vendor_email, invoice_date (YYYY-MM-DD), due_date (YYYY-MM-DD), currency (ISO 4217), subtotal, tax_total, total_amount, po_number, line_items (mảng {description, quantity, unit_price, amount}). Thiếu thì để null. Chỉ trả JSON." User message: nội dung invoice_json hoặc file_url từ scenario inputs/trigger.
3. **JSON > Parse JSON** — parse nội dung message của module 2 theo schema các field trên.
4. **Tools > Set variable** — invoice_id = formatDate(now; "yyyyMMddHHmmss"); total_amount = number(parse JSON.total_amount); approval_threshold = ifnull(scenario input auto_approve_threshold; 5000000).
5. **Google Sheets > Search rows** — spreadsheet "Invoice Ledger", sheet "Invoices", filter invoice_number = invoice_number đã parse, limit 1.
6. **Router "Validation"** — path Invalid nếu invoice_number rỗng HOẶC total_amount ≤ 0 HOẶC vendor_name rỗng; path Valid cho phần còn lại.
7. **Router "Duplicate check"** — path Duplicate nếu Search rows (module 5) có ≥1 kết quả; path New nếu không.
8. **Router "Approval"** — path "Need approval" nếu total_amount > approval_threshold; path "Auto-approve" cho phần còn lại.

**Path Auto-approve:**
9. **Google Sheets > Add a row** — sheet "Invoices", cột: invoice_id, invoice_number, vendor_name, vendor_email, invoice_date, due_date, subtotal, tax_total, total_amount, currency, po_number, status="Approved", source, file_url, line_items_json, created_at=now.
10. **HTTP > Get a file** — tải file từ file_url (chỉ khi có file_url).
11. **Google Drive > Upload a file** — folder "Invoices/<year>/<month>/<vendor_name>/", tên file "<invoice_number>_<vendor_name>.pdf".
12. **Slack > Send a message** — channel #finance, tóm tắt invoice + link file đã lưu.
13. **Scenarios > Return output** — status=success, approval_required=false, approval_decision=not_required, invoice_id, vendor_name, total_amount, currency, ledger_row_url, file_archive_url, message.

**Path Need approval:**
14. **Google Sheets > Add a row** — sheet "Invoices", status="Pending approval".
15. **Slack > Send a message** — channel = notify_channel, nội dung yêu cầu phê duyệt kèm 2 link:
    - Approve: `<APPROVAL_WEBHOOK_URL>?decision=approve&invoice_id=<invoice_id>&token=<SHARED_SECRET>`
    - Reject: `<APPROVAL_WEBHOOK_URL>?decision=reject&invoice_id=<invoice_id>&token=<SHARED_SECRET>`
    Trong đó `<APPROVAL_WEBHOOK_URL>` là URL webhook của Scenario 2 (tạo ở dưới), `<SHARED_SECRET>` là chuỗi bí mật do tôi cung cấp.
16. **Scenarios > Return output** — status=pending, approval_required=true, approval_decision=pending, invoice_id, vendor_name, total_amount, currency, message="Đã gửi yêu cầu phê duyệt".

**Path Exception (từ Router Validation → Invalid):**
17. **Google Sheets > Add a row** — sheet "Exceptions" (raw payload + lý do) → **Slack > Send a message** tới #finance-exceptions → **Scenarios > Return output** status=exception, message=lý do.

**Path Duplicate (từ Router Duplicate → Duplicate):**
18. **Slack > Send a message** thông báo trùng → **Scenarios > Return output** status=duplicate.

**Error path (error handler của mọi module):**
19. **Slack > Send a message** tới #finance-errors (tên module + error message) → **Scenarios > Return output** status=error.

## SCENARIO 2: "Approval Handler"

### Flow
1. **Webhooks > Custom webhook** — trigger, tên "Invoice Approval". Định nghĩa data structure với các field decision (Text), invoice_id (Text), token (Text). **Copy URL webhook này** — cần nhúng vào module 15 của Scenario 1.
2. **Router "Validate token"** — path Valid nếu query token = `<SHARED_SECRET>`; path Invalid → **Slack > Send a message** tới #finance-errors + **Webhooks > Webhook response** (status 403, body "Forbidden").
3. **Google Sheets > Search rows** — sheet "Invoices", filter invoice_id = invoice_id từ webhook, limit 1.
4. **Google Sheets > Update a row** — row ID từ module 3, cập nhật status = Approved nếu decision=approve, ngược lại Rejected (dùng formula if/equals trong mapping field).
5. **Router "Decision"** — path approve nếu decision = "approve"; path reject cho phần còn lại.
6. **Path approve**: **HTTP > Get a file** (file_url từ row) → **Google Drive > Upload a file** (folder Invoices/<year>/<month>/<vendor_name>/) → **Slack > Send a message** (#finance: "Invoice ... đã được PHÊ DUYỆT") → **Webhooks > Webhook response** (status 200, body "Approved", header Content-type: text/plain).
7. **Path reject**: **Slack > Send a message** (#finance: "Invoice ... đã bị TỪ CHỐI") → **Webhooks > Webhook response** (status 200, body "Rejected").

## JSON schema payload invoice (dùng cho module 1 Scenario 1 và data structure)

```json
{
  "invoice_number": "string (required)",
  "vendor_name": "string (required)",
  "vendor_email": "string (email, optional)",
  "invoice_date": "date YYYY-MM-DD",
  "due_date": "date YYYY-MM-DD",
  "currency": "ISO 4217, vd VND/USD (required)",
  "subtotal": "number",
  "tax_total": "number",
  "total_amount": "number > 0 (required)",
  "po_number": "string",
  "line_items": [{"description": "string", "quantity": "number", "unit_price": "number", "amount": "number"}],
  "file_url": "uri (optional)",
  "source": "email | api | drive | manual"
}
```

## Sample payload để test

```json
{"invoice_number":"INV-2026-001","vendor_name":"ACB Supply Co","vendor_email":"ap@acbsupply.example","invoice_date":"2026-10-01","due_date":"2026-10-31","currency":"VND","subtotal":42000000,"tax_total":4200000,"total_amount":46200000,"po_number":"PO-7788","line_items":[{"description":"Office chairs","quantity":20,"unit_price":2100000,"amount":42000000}],"file_url":"https://example.com/invoices/INV-2026-001.pdf","source":"api"}
```

## Thứ tự thực hiện

1. Tạo Scenario 2 trước (để có APPROVAL_WEBHOOK_URL).
2. Tạo Scenario 1, nhúng APPROVAL_WEBHOOK_URL và SHARED_SECRET vào module 15.
3. Chạy thử Scenario 1 với sample payload, kiểm tra kết quả.
4. Test approval: gọi webhook Scenario 2 với `?decision=approve&invoice_id=<id>&token=<secret>`, kiểm tra sổ cái cập nhật.
5. Báo tôi: webhook URL của cả 2 scenario, danh sách module đã tạo, và kết quả test.
