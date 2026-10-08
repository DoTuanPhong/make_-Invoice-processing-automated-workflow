# Scenario Inputs & Outputs (cho MCP)

Để Scenario 1 ("Invoice Processing") hiện làm **MCP tool** trong Cursor/Claude, cần cấu hình:

1. Scenario **Active** + scheduling **On demand**
2. Khai báo **Scenario inputs** (tham số AI truyền vào khi gọi tool)
3. Khai báo **Scenario outputs** (dữ liệu trả về cho AI)
4. Module cuối mỗi path là `Scenarios > Return output` map đầy đủ outputs
5. Mô tả scenario rõ ràng (Diagram → Options → Edit description)

> Scenario 2 ("Approval Handler") là webhook-triggered, KHÔNG cần khai báo inputs/outputs cho MCP.

## Scenario inputs (Scenario 1)

| Name | Type | Required | Default | Mô tả |
|---|---|---|---|---|
| `invoice_json` | Text (JSON string) | No | — | Dữ liệu invoice dạng JSON (dùng khi gọi qua MCP thay cho webhook). Cấu trúc theo `03-webhook-payload-schema.json`. |
| `file_url` | Text (URL) | No | — | URL file PDF/image invoice (dùng cùng invoice_json hoặc thay thế). |
| `auto_approve_threshold` | Number | No | `5000000` | Số tiền tối đa được tự động duyệt (đơn vị theo currency). Vượt ngưỡng → gửi yêu cầu phê duyệt. |
| `notify_channel` | Text | No | `#finance` | Slack channel nhận thông báo. |

Cách map vào flow:
- Module [2] OpenAI: user message map từ `{{Scenario inputs.file_url}}` nếu có, nếu không thì `{{Scenario inputs.invoice_json}}` (hoặc `{{1. Custom webhook}}` khi chạy qua webhook).
- Module [4] Set variable: `approval_threshold` = `{{ifnull(Scenario inputs.auto_approve_threshold; 5000000)}}`.
- Module [10] Slack: channel = `{{ifnull(Scenario inputs.notify_channel; "#finance")}}`.

> Khi chạy on-demand (qua MCP hoặc nút Run), Make inject scenario inputs vào bundle của trigger module, nên các module map từ `1. Custom webhook` vẫn nhận được dữ liệu.

## Scenario outputs (Scenario 1)

| Name | Type | Mô tả |
|---|---|---|
| `status` | Text | `success` \| `pending` \| `exception` \| `duplicate` \| `error` |
| `invoice_id` | Text | ID nội bộ sinh ra (timestamp-based), dùng để approve/reject |
| `vendor_name` | Text | Tên nhà cung cấp |
| `total_amount` | Number | Tổng tiền invoice |
| `currency` | Text | Mã tiền tệ ISO 4217 (VND, USD...) |
| `approval_required` | Boolean | Có cần phê duyệt thủ công không |
| `approval_decision` | Text | `not_required` \| `pending` \| `approved` \| `rejected` |
| `ledger_row_url` | Text | URL Google Sheets row (nếu có) |
| `file_archive_url` | Text | URL file PDF trên Google Drive (nếu có) |
| `message` | Text | Tóm tắt kết quả / lý do lỗi |

## Ví dụ gọi tool qua MCP

Prompt trong Cursor/Claude:

> Dùng Make xử lý invoice này:
> ```json
> {"invoice_number":"INV-2026-001","vendor_name":"ACB Supply Co","vendor_email":"ap@acbsupply.example","invoice_date":"2026-10-01","due_date":"2026-10-31","currency":"VND","subtotal":42000000,"tax_total":4200000,"total_amount":46200000,"po_number":"PO-7788","line_items":[{"description":"Office chairs","quantity":20,"unit_price":2100000,"amount":42000000}],"file_url":"https://example.com/invoices/INV-2026-001.pdf","source":"api"}
> ```

AI sẽ gọi tool `Invoice Processing` với `invoice_json` = payload trên, rồi trả về kết quả. Ví dụ kết quả:

- Dưới ngưỡng: `{"status":"success","invoice_id":"20261007193000","vendor_name":"ACB Supply Co","total_amount":46200000,"currency":"VND","approval_required":false,"approval_decision":"not_required",...}`
- Vượt ngưỡng: `{"status":"pending","approval_required":true,"approval_decision":"pending","message":"Đã gửi yêu cầu phê duyệt đến #finance",...}`

## Kiểm tra tool đã sẵn sàng

Trong Cursor chat: *"What tools do you have from Make MCP server?"* → phải thấy tool tên scenario với các input/output trên. Nếu không thấy: kiểm tra scenario đã Active + On demand chưa, và MCP token có scope `mcp:use` không.

## Theo dõi trạng thái phê duyệt

Khi `status=pending`, invoice đang chờ phê duyệt. Trạng thái cập nhật khi ai đó click link approve/reject (Scenario 2 chạy). Để kiểm tra trạng thái hiện tại bằng AI, tạo thêm 1 scenario on-demand đơn giản: `Google Sheets > Search rows` (filter invoice_id) → `Scenarios > Return output` (status, approval_decision) — rồi expose làm MCP tool `Get invoice status`.
