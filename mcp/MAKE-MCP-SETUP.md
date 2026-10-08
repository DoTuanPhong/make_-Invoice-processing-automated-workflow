# Cài đặt Make MCP Server

Make MCP server là server đám mây do Make host (không cần cài local), cho phép AI assistant (Cursor, Claude, ChatGPT...) **chạy scenario** và **quản lý account Make** (tạo/sửa scenario, webhook, data store...) qua giao thức MCP.

Make MCP server hỗ trợ **2 cách kết nối** (chọn 1):

| Phương thức | Server URL | Key | Khi nào dùng |
|---|---|---|---|
| **MCP Toolbox** (khuyến nghị) | `https://<ZONE>/mcp/server/<TOOLBOX_ID>` | Toolbox Key | Chỉ expose các scenario đã chọn trong toolbox làm tool |
| **MCP token** | `https://<ZONE>/mcp` | MCP token | Chạy mọi scenario on-demand + active (cần scope `mcp:use`) |

## Bước 1: Lấy Server URL + Key

**Cách A — MCP Toolbox (khuyến nghị):**
1. Make.com → menu trái → **MCP toolboxes** (hoặc tìm "MCP toolboxes")
2. **Create toolbox** → đặt tên (ví dụ `Invoice Processing`)
3. Chọn các scenario on-demand + active muốn expose làm tool → **Save**
4. Trong toolbox, tab **Connect your MCP toolbox to an MCP client** → copy **MCP Server URL** (`https://<ZONE>/mcp/server/<id>`) và **Toolbox Key**

**Cách B — MCP token:**
1. Make.com → tên bạn (góc trên phải) → **Profile** → tab **API access**
2. Trong **Tokens**, click **Add token**
3. Chọn scopes: `mcp:use` (chạy scenario — mọi plan) + management scopes (paid plan)
4. Đặt **Label** → **Add** → **copy token ngay** (chỉ hiện 1 lần)

**Lấy MAKE_ZONE**: nhìn vào URL Make của bạn, ví dụ `https://us2.make.com/...` → zone là `us2.make.com`.

## Bước 2: Cấu hình vào MCP client

### Tự động (khuyến nghị)

```powershell
# MCP Toolbox:
.\mcp\install-mcp.ps1 -ServerUrl "https://us2.make.com/mcp/server/<TOOLBOX_ID>" -AuthKey "<TOOLBOX_KEY>"

# Hoặc MCP token:
.\mcp\install-mcp.ps1 -ServerUrl "https://us2.make.com/mcp" -AuthKey "<MCP_TOKEN>"
```

Script sẽ hỏi Server URL + Key nếu không truyền tham số, rồi ghi config vào:
- `%APPDATA%\Cursor\mcp.json` (Cursor — url + Authorization header)
- `%APPDATA%\Claude\claude_desktop_config.json` (Claude Desktop — mcp-remote + --header)
- `%USERPROFILE%\.config\kilo\kilo.json` (Kilo trong VS Code — key `mcp`, type `remote`)

### Thủ công

**Kilo** (`.kilo/kilo.json` trong project hoặc `~/.config/kilo/kilo.json` global):

```json
{
  "mcp": {
    "make": {
      "type": "remote",
      "url": "https://<ZONE>/mcp/server/<TOOLBOX_ID>",
      "headers": {
        "Authorization": "Bearer <TOOLBOX_KEY>"
      },
      "enabled": true
    }
  }
}
```

**Cursor** (`%APPDATA%\Cursor\mcp.json` hoặc `.cursor/mcp.json` trong project):

```json
{
  "mcpServers": {
    "make": {
      "url": "https://<ZONE>/mcp/server/<TOOLBOX_ID>",
      "headers": {
        "Authorization": "Bearer <TOOLBOX_KEY>"
      }
    }
  }
}
```

**Claude Desktop** (`%APPDATA%\Claude\claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "make": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "https://<ZONE>/mcp/server/<TOOLBOX_ID>",
        "--header",
        "Authorization: Bearer <TOOLBOX_KEY>"
      ]
    }
  }
}
```

**Claude Code** (terminal):

```bash
claude mcp add --transport http make https://<ZONE>/mcp/server/<TOOLBOX_ID> --header "Authorization: Bearer <TOOLBOX_KEY>"
```

**OpenAI Responses API** (nếu dùng GPT):

```bash
curl https://api.openai.com/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
  "model": "gpt-4.1",
  "input": "List all available tools.",
  "tools": [
    {
      "type": "mcp",
      "server_label": "make",
      "server_url": "https://<ZONE>/mcp/server/<TOOLBOX_ID>/t/<TOOLBOX_KEY>/stateless"
    }
  ]
}'
```

> Lưu ý: transport key-in-URL dùng `/stateless` (đã test: `/sse` trả 404, `/stateless` hoạt động). Client hỗ trợ header thì dùng header `Authorization: Bearer` cho đơn giản.

**OAuth (không cần key/token)** — dùng URL `https://mcp.make.com` trong client hỗ trợ OAuth (Claude Desktop: Settings → Connectors → Browse connectors → tìm **Make**). OAuth giới hạn scope theo org, an toàn hơn cho team.

## Bước 3: Kiểm tra kết nối

- **Cursor**: Command Palette (`Ctrl+Shift+P`) → `MCP` → xem server `make` status = connected; hoặc chat: *"What tools do you have from Make MCP server?"*
- **Claude Code**: chạy `/mcp`
- **MCP Inspector** (kiểm tra tool list):
  ```powershell
  npx @modelcontextprotocol/inspector --cli https://<MAKE_ZONE>/mcp --transport http --header "Authorization: Bearer <MCP_TOKEN>"
  ```

## Ghi chú quan trọng

- Scenario chỉ hiện làm MCP tool khi **Active** + scheduling **On demand** (xem `workflow\02-scenario-inputs-outputs.md`).
- Timeout khi chạy scenario qua MCP: 40s (token) / 25s (OAuth). Nếu quá, scenario vẫn chạy tiếp trong Make tối đa 40 phút và trả về `executionId` để lấy kết quả sau (cần scope `scenarios:read`).
- Tên tool mặc định bị crop còn 56 ký tự; có thể kéo dài bằng query `?maxToolNameLength=120` (range 32–160).
- Nên cài thêm **Make Skills** (https://skills.make.com/) để AI build scenario chính xác hơn.

## Tài liệu tham khảo

- Developer Hub: https://developers.make.com/mcp-server
- Help Center: https://help.make.com/make-mcp-server
