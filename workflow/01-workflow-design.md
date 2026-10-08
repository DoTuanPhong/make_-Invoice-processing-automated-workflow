# Thiết kế Scenario: Invoice Processing Automation

Kiến trúc **2 scenarios** (pattern khuyến nghị của Make community cho approval/human-in-the-loop):

- **Scenario 1 — "Invoice Processing"**: nhận invoice, trích xuất AI, validate, kiểm tra trùng, tự duyệt hoặc gửi yêu cầu phê duyệt. Đây là scenario được expose làm MCP tool.
- **Scenario 2 — "Approval Handler"**: nhận quyết định phê duyệt từ link approve/reject, cập nhật sổ cái, hoàn tất xử lý.

## Kết nối (Connections) cần tạo trong Make

Tạo trước trong Make (thanh trái → Connections → Create a connection):

| App | Mục đích | Ghi chú |
|---|---|---|
| **Webhooks** | Trigger + webhook response | Không cần auth |
| **OpenAI** (hoặc **Anthropic**) | Trích xuất dữ liệu từ PDF/image invoice | Cần API key; model phải có vision (GPT-4o / Claude Sonnet) |
| **Google Sheets** | Sổ cái invoice | Tạo spreadsheet `Invoice Ledger`, 2 sheets: `Invoices`, `Exceptions` |
| **Google Drive** | Lưu trữ file PDF | Tạo folder `Invoices` |
| **Slack** | Thông báo + yêu cầu phê duyệt | Hoặc dùng Email nếu không có Slack |
| **Email** (Gmail/SMTP) | Gửi yêu cầu approve + xác nhận | Tùy chọn |

## Google Sheets — cấu trúc sổ cái

Sheet `Invoices`, cột (hàng 1 = tiêu đề):

`invoice_id | invoice_number | vendor_name | vendor_email | invoice_date | due_date | subtotal | tax_total | total_amount | currency | po_number | status | source | file_url | line_items_json | created_at`

Sheet `Exceptions`, cột: `invoice_id | raw_payload | error_reason | created_at`

---

# SCENARIO 1: Invoice Processing

## Sơ đồ module

```
[1] Webhooks > Custom webhook                    (trigger — nhận invoice)
      ↓
[2] OpenAI > Create a chat completion            (trích xuất JSON)
      ↓
[3] JSON > Parse JSON                            (chuẩn hóa cấu trúc)
      ↓
[4] Tools > Set variable                         (invoice_id, total_amount, threshold)
      ↓
[5] Google Sheets > Search rows                  (kiểm tra trùng invoice_number)
      ↓
[6] Router: Validation
      ├─ Valid ──────────────────────┐
      └─ Invalid → [E] Exception path
                    ↓
[7] Router: Duplicate check
      ├─ New ───────────────┐
      └─ Duplicate → [D] Duplicate path
                    ↓
[8] Router: Approval (total_amount > threshold?)
      ├─ Auto-approve → [12] Google Sheets > Add a row (status=Approved)
      │                    ↓
      │                 [13] HTTP > Get a file
      │                    ↓
      │                 [14] Google Drive > Upload a file
      │                    ↓
      │                 [15] Slack > Send a message (#finance)
      │                    ↓
      │                 [17] Scenarios > Return output (status=success)
      │
      └─ Need approval → [9] Google Sheets > Add a row (status=Pending approval)
                           ↓
                        [10] Slack > Send a message (link approve/reject → Scenario 2)
                           ↓
                        [17] Scenarios > Return output (status=pending, approval_required=true)

[E] Exception path: [E1] Google Sheets > Add a row (sheet Exceptions)
                    → [E2] Slack > Send a message (#finance-exceptions)
                    → [E3] Scenarios > Return output (status=exception)

[D] Duplicate path: [D1] Slack > Send a message
                    → [D2] Scenarios > Return output (status=duplicate)

[ERR] Error path (error handler của mọi module):
      [X1] Slack > Send a message (#finance-errors)
      → [X2] Scenarios > Return output (status=error)
```

## Cấu hình từng module

### [1] Webhooks > Custom webhook (Trigger)
- Tạo webhook mới, đặt tên `Invoice Intake`. Copy URL (dùng cho script test và tích hợp bên ngoài).
- **Advanced settings**:
  - **Data structure**: tạo data structure theo `03-webhook-payload-schema.json` (các field: invoice_number, vendor_name, vendor_email, invoice_date, due_date, currency, subtotal, tax_total, total_amount, po_number, line_items, file_url, source). Make sẽ validate payload đầu vào (reject 400 nếu sai).
  - **Get request HTTP method**: Yes (để log/kiểm tra).
- Khi chạy on-demand qua MCP, scenario inputs được inject vào bundle của trigger — module bên dưới map từ `1. Custom webhook` vẫn hoạt động.

### [2] OpenAI > Create a chat completion
- **Model**: `gpt-4o` (hoặc `gpt-4o-mini` tiết kiệm hơn; hoặc `claude-sonnet-4` nếu dùng Anthropic)
- **Messages**:
  - **System**: *"Bạn là assistant trích xuất dữ liệu hóa đơn. Trả về MỘT object JSON duy nhất với các keys: invoice_number, vendor_name, vendor_email, invoice_date (YYYY-MM-DD), due_date (YYYY-MM-DD), currency (ISO 4217, vd VND/USD), subtotal, tax_total, total_amount, po_number, line_items (mảng các object {description, quantity, unit_price, amount}). Nếu thiếu thông tin thì để null. Không giải thích, chỉ trả JSON."*
  - **User**: map `{{1. Custom webhook.file_url}}` kèm text *"Trích xuất dữ liệu từ hóa đơn tại URL này"*; nếu payload đã chứa đầy đủ JSON (không có file) thì map toàn bộ JSON vào user message.
- **Response format**: JSON object (nếu model hỗ trợ).

### [3] JSON > Parse JSON
- **JSON string**: `{{2. Create a chat completion.choices[0].message.content}}`
- **Schema**: khai báo các field: invoice_number (Text), vendor_name (Text), vendor_email (Text), invoice_date (Text), due_date (Text), currency (Text), subtotal (Number), tax_total (Number), total_amount (Number), po_number (Text), line_items (Array), file_url (Text), source (Text).

### [4] Tools > Set variable
- `invoice_id`: `{{formatDate(now; "yyyyMMddHHmmss")}}`
- `total_amount`: `{{number(3. Parse JSON.total_amount)}}`
- `approval_threshold`: `{{ifnull(Scenario inputs.auto_approve_threshold; 5000000)}}` — map từ scenario input, default 5.000.000.

> Nếu builder của bạn không còn "Tools > Set variable", dùng **Make Functions > General functions** (operation: If empty / Get) hoặc **Make Functions > Transform** để đạt kết quả tương tự.

### [5] Google Sheets > Search rows
- Spreadsheet: `Invoice Ledger`, sheet `Invoices`
- Filter: `invoice_number` **equals** `{{3. Parse JSON.invoice_number}}`
- Limit: 1

### [6] Router: Validation
- **Path "Invalid"** (điều kiện OR):
  - `{{3. Parse JSON.invoice_number}}` không tồn tại / rỗng, HOẶC
  - `{{4. Set variable.total_amount}}` ≤ 0, HOẶC
  - `{{3. Parse JSON.vendor_name}}` rỗng
- **Path "Valid"**: else (mặc định).

### [7] Router: Duplicate check
- **Path "Duplicate"**: Search rows (module 5) trả về ≥ 1 row — đặt condition trên giá trị first row (ví dụ first row ID exists), hoặc dùng formula `length(5. Search rows) > 0`.
- **Path "New"**: else.

### [8] Router: Approval
- **Path "Need approval"**: `{{4. Set variable.total_amount}}` **>** `{{4. Set variable.approval_threshold}}`
- **Path "Auto-approve"**: else.

### [9] Google Sheets > Add a row (trên path Need approval)
- Sheet `Invoices`, map đầy đủ cột; `status` = `Pending approval`; `created_at` = `{{now}}`.

### [10] Slack > Send a message (hoặc Email > Send an email)
- Channel: `{{Scenario inputs.notify_channel}}` (default `#finance`)
- Text: yêu cầu phê duyệt invoice `{{invoice_number}}` — vendor `{{vendor_name}}` — amount `{{total_amount}} {{currency}}`, kèm 2 link:
  - **Approve**: `<WEBHOOK_URL_SCENARIO_2>?decision=approve&invoice_id={{4. Set variable.invoice_id}}&token=<SHARED_SECRET>`
  - **Reject**: `<WEBHOOK_URL_SCENARIO_2>?decision=reject&invoice_id={{4. Set variable.invoice_id}}&token=<SHARED_SECRET>`
- `<WEBHOOK_URL_SCENARIO_2>` = URL webhook tĩnh của Scenario 2 (copy từ module [1] của Scenario 2). `<SHARED_SECRET>` = chuỗi bí mật tự chọn, dùng để chống approve giả mạo (Scenario 2 sẽ kiểm tra).

### [12] Google Sheets > Add a row (trên path Auto-approve)
- Tương tự [9] nhưng `status` = `Approved`.

### [13] HTTP > Get a file
- URL: `{{1. Custom webhook.file_url}}` — chỉ chạy khi có `file_url` (bỏ qua nếu payload đã đủ dữ liệu).

### [14] Google Drive > Upload a file
- Folder: `Invoices/{{year(invoice_date)}}/{{month(invoice_date)}}/{{vendor_name}}/` (dùng `Google Drive > Create a folder` trước nếu cần tạo path).
- File name: `{{invoice_number}}_{{vendor_name}}.pdf`
- Source file: output của [13].

### [15] Slack > Send a message
- Channel `#finance`: *"Invoice {{invoice_number}} từ {{vendor_name}} — {{total_amount}} {{currency}} — trạng thái: Approved — file: {{14. Upload a file.url}}"*

### [17] Scenarios > Return output
Map các scenario outputs (khai báo xem `02-scenario-inputs-outputs.md`):
- Path Auto-approve: `status`=`success`, `approval_required`=`false`, `approval_decision`=`not_required`, `invoice_id`, `vendor_name`, `total_amount`, `currency`, `ledger_row_url`, `file_archive_url`, `message`.
- Path Need approval: `status`=`pending`, `approval_required`=`true`, `approval_decision`=`pending`, `message`="Đã gửi yêu cầu phê duyệt".

## Các path phụ

### [E] Exception path (validation fail)
- [E1] `Google Sheets > Add a row` vào sheet `Exceptions`: raw payload + lý do.
- [E2] `Slack > Send a message` tới `#finance-exceptions`: *"Invoice không hợp lệ: {lý do}. Raw: {payload}"*.
- [E3] `Scenarios > Return output`: `status`=`exception`, `message`=lý do.

### [D] Duplicate path
- [D1] `Slack > Send a message`: *"Invoice trùng: {{invoice_number}} đã tồn tại (row {{5. Search rows.id}})"*.
- [D2] `Return output`: `status`=`duplicate`.

### [X] Error path (toàn cục)
- Bật **On error** cho từng module (click chuột phải module → *Add error handler* / cấu hình error handling) → nối vào:
- [X1] `Slack > Send a message` tới `#finance-errors`: tên module lỗi + error message.
- [X2] `Scenarios > Return output`: `status`=`error`, `message`=error.

## Scenario 1 settings

- **Scheduling**: `On demand` (bắt buộc để MCP discovery).
- **Activate**: ON.
- **Options → Description**: *"Xử lý invoice tự động: nhận invoice qua webhook hoặc MCP input, trích xuất dữ liệu bằng AI, kiểm tra trùng/lỗi, phê duyệt nếu vượt ngưỡng, ghi sổ cái Google Sheets, lưu PDF Google Drive, thông báo Slack. Trả về status, invoice_id, vendor, total."*
- **Process data in order**: bật nếu muốn xử lý tuần tự (tránh race condition khi nhiều invoice cùng lúc).

---

# SCENARIO 2: Approval Handler

## Sơ đồ module

```
[1] Webhooks > Custom webhook          (trigger — nhận approve/reject click)
      ↓
[2] Router: Validate token             (token query ≠ shared secret → [R] Reject path)
      ↓
[3] Google Sheets > Search rows        (tìm row theo invoice_id)
      ↓
[4] Google Sheets > Update a row       (status = Approved / Rejected)
      ↓
[5] Router: decision
      ├─ approve → [6] HTTP > Get a file → [7] Google Drive > Upload a file
      │             → [8] Slack > Send a message (#finance)
      │             → [10] Webhooks > Webhook response (200 "Approved")
      └─ reject  → [9] Slack > Send a message (#finance + requester)
                    → [10] Webhooks > Webhook response (200 "Rejected")

[R] Reject path (token sai): [R1] Slack > Send a message (#finance-errors)
                             → [R2] Webhooks > Webhook response (403 "Forbidden")
```

## Cấu hình từng module

### [1] Webhooks > Custom webhook (Trigger)
- Tạo webhook mới, đặt tên `Invoice Approval`. **Copy URL** — đây là URL nhúng vào link approve/reject của Scenario 1 (module [10]).
- **Advanced settings**:
  - **Data structure**: tạo structure với `decision` (Text), `invoice_id` (Text), `token` (Text) — query string params tự động map vào bundle.
  - **Get request HTTP method**: Yes.
- URL có dạng: `https://hook.<zone>.make.com/<webhook-id>`

### [2] Router: Validate token
- **Path "Valid"**: `{{1. Custom webhook.token}}` **equals** `<SHARED_SECRET>` (cùng secret với module [10] Scenario 1).
- **Path "Invalid"**: else → [R] Reject path (chống approve giả mạo qua URL đoán được).

### [3] Google Sheets > Search rows
- Sheet `Invoices`, filter: `invoice_id` **equals** `{{1. Custom webhook.invoice_id}}`, limit 1.

### [4] Google Sheets > Update a row
- Row ID: output của [3]. Cập nhật `status`:
  - Dùng **Make Functions > General functions** (operation: If) hoặc 2 update module trên 2 router path để set `Approved` / `Rejected`.
  - Đơn giản hơn: update `status` = `{{if(equals(1. Custom webhook.decision; "approve"); "Approved"; "Rejected")}}` (formula trong mapping field).

### [5] Router: decision
- **Path "approve"**: `{{1. Custom webhook.decision}}` **equals** `approve`
- **Path "reject"**: else.

### [6] HTTP > Get a file + [7] Google Drive > Upload a file
- Tải PDF từ `file_url` (lấy từ row [3]) và lưu vào `Invoices/{nam}/{thang}/{vendor}/` như Scenario 1 module [13][14].

### [8] Slack > Send a message (approve)
- `#finance`: *"Invoice {{invoice_number}} ({{vendor_name}}, {{total_amount}} {{currency}}) đã được PHÊ DUYỆT. File: {{7. Upload a file.url}}"*

### [9] Slack > Send a message (reject)
- `#finance`: *"Invoice {{invoice_number}} ({{vendor_name}}) đã bị TỪ CHỐI."*
- Tùy chọn: `Email > Send an email` cho requester.

### [10] Webhooks > Webhook response
- **Status**: `200`
- **Body**: text `Approved` hoặc `Rejected` (tùy path) — hiển thị trên trình duyệt khi user click link.
- **Custom headers**: `Content-type` = `text/plain`.

### [R] Reject path (token sai)
- [R1] `Slack > Send a message` tới `#finance-errors`: *"Approval request bị từ chối: token không đúng (invoice_id={{invoice_id}})"*.
- [R2] `Webhooks > Webhook response`: Status `403`, Body `Forbidden`.

## Scenario 2 settings

- **Scheduling**: `Immediately as data arrives` (webhook trigger — luôn bật để nhận click).
- **Activate**: ON.
- **Process data in order**: bật (tránh 2 người click đồng thời ghi đè nhau).

---

# Variants (tuỳ chọn)

- **Trigger email thay cho webhook**: thay [1] Scenario 1 bằng `Gmail > Watch emails` (filter `has:attachment subject:invoice`) → `Gmail > Download an attachment` → [2]. Hoặc dùng `Webhooks > Custom mailhook` (mailhook address làm nơi forwarding email).
- **Trigger Google Drive**: `Google Drive > Watch files` trong folder `Invoices-Inbox` → [2].
- **Push thẳng vào accounting**: thay [12] bằng `Xero > Create a bill` hoặc `QuickBooks > Create a bill` (draft).
- **Slack interactive buttons**: thay link approve/reject bằng Slack message buttons → Scenario 2 trigger = `Slack > Watch instant webhooks` (cần cấu hình Slack app interactive components).
- **Tools > Wait for webhook**: module này sinh webhook URL tại runtime (khi scenario chạy đến nó), nên KHÔNG dùng được để nhúng URL vào message gửi trước đó. Chỉ phù hợp cho pattern callback từ API bên ngoài. Giữ nguyên kiến trúc 2 scenarios ở trên.
- **Dynamic webhook**: `Webhooks > Create a webhook` (action) tạo webhook tại runtime và trả URL làm output — dùng khi cần 1 webhook mới cho mỗi lần chạy (ví dụ: truyền callback URL cho API bên ngoài qua HTTP module).
