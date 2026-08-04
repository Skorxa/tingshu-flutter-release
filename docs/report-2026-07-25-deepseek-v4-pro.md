```json
{
  "scene": "跨平台小说/有声书聚合搜索与阅读",
  "scenario": "用户登录、浏览平台、搜索书籍（文本/音频）、查看详情、阅读/收听、记录进度",
  "user_identity": {
    "username": "company_ozone238",
    "email": "company_ozone238@yuanyoupush.com",
    "role": 0,
    "id": 934
  },
  "interaction_flow": [
    {
      "step": 1,
      "action": "登录",
      "endpoint": "POST /api/v1/auth/login",
      "body": {
        "email": "company_ozone238@yuanyoupush.com",
        "password": "company_ozone238@yuanyoupush.com"
      },
      "response": {
        "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
        "user": { "id": 934, ... }
      },
      "result": "获取JWT token并存入localStorage.token"
    },
    {
      "step": 2,
      "action": "获取公告",
      "endpoint": "GET /api/v1/announcements",
      "auth": "Bearer token",
      "response": [{ "id": 2, "title": "该站点运营by xi~", ... }, { "id": 1, "title": "书源还没写，先用web吧", ... }]
    },
    {
      "step": 3,
      "action": "获取平台列表",
      "endpoint": "GET /api/v1/platforms",
      "auth": "Bearer token",
      "response": [
        { "id": "fanqie", "name": "番茄小说", "has_content": true, "has_audio": true, "has_video": true, "has_comic": true, "search_tabs": [...] },
        { "id": "qimao", "name": "七猫", ... },
        ...
      ]
    },
    {
      "step": 4,
      "action": "获取阅读历史（初始为空）",
      "endpoint": "GET /api/v1/reading/history?page=1&size=10"
    },
    {
      "step": 5,
      "action": "获取书架（初始为空）",
      "endpoint": "GET /api/v1/shelf?page=1&size=10"
    },
    {
      "step": 6,
      "action": "获取个人资料",
      "endpoint": "GET /api/v1/auth/profile"
    },
    {
      "step": 7,
      "action": "获取配额信息",
      "endpoint": "GET /api/v1/quota",
      "response": {
        "fanqie": { "total": 800, "used": 0, "remaining": 800 },
        "qimao": { "total": 400, "used": 0, "remaining": 400 },
        "ximalaya": { "total": 200, "used": 0, "remaining": 200 },
        ...
      }
    },
    {
      "step": 8,
      "action": "获取配额使用日志",
      "endpoint": "GET /api/v1/quota/logs?page=1&size=20"
    },
    {
      "step": 9,
      "action": "搜索番茄小说文本 '剑来'",
      "endpoint": "GET /api/v1/search?platform=fanqie&q=%E5%89%91%E6%9D%A5&page=0&tab_type=3"
    },
    {
      "step": 10,
      "action": "批量检查搜索结果是否在书架",
      "endpoint": "POST /api/v1/shelf/status",
      "body": { "items": [{ "platform":"fanqie","book_id":"...","content_type":"text" }, ... ] }
    },
    {
      "step": 11,
      "action": "查看第一本书详情、目录、阅读历史状态、书架状态（重复多次，可能是多Tab或轮询）",
      "endpoints": [
        "GET /api/v1/books/fanqie/7422707296066604094?content_type=text",
        "GET /api/v1/books/fanqie/7422707296066604094/catalog?content_type=text&page=1",
        "GET /api/v1/shelf/status?platform=fanqie&book_id=7422707296066604094&content_type=text",
        "GET /api/v1/reading/history/status?platform=fanqie&book_id=7422707296066604094&content_type=text"
      ]
    },
    {
      "step": 12,
      "action": "获取全书目录（完整模式）",
      "endpoint": "GET /api/v1/books/fanqie/7422707296066604094/catalog?content_type=text&mode=full"
    },
    {
      "step": 13,
      "action": "获取章节内容 (第1章)",
      "endpoint": "GET /api/v1/books/fanqie/7422707296066604094/chapters/7422904810468295192",
      "response": { "content": "<header>...</header><article>...</article>" }
    },
    {
      "step": 14,
      "action": "更新阅读历史（文本），进度设为0，chapter_position=1",
      "endpoint": "PUT /api/v1/reading/history",
      "body": { "platform":"fanqie","book_id":"...","chapter_id":"...","progress":0,"chapter_position":1,"book_title":"...","content_type":"text",... }
    },
    {
      "step": 15,
      "action": "再次搜索番茄小说，切换 tab 为 '听书'",
      "endpoint": "GET /api/v1/search?platform=fanqie&q=%E5%89%91%E6%9D%A5&page=0&tab_type=2"
    },
    {
      "step": 16,
      "action": "批量检查听书搜索结果是否在书架",
      "endpoint": "POST /api/v1/shelf/status",
      "body": { "items": [...] }
    },
    {
      "step": 17,
      "action": "查看有声书《光阴之外》详情、目录，获取音频资源，更新阅读历史，多次上报播放进度（progress 0 -> 0.79 -> 1.63 -> 2.45 -> 2.59）",
      "endpoints": [
        "GET /api/v1/books/fanqie/7304106523137952830?content_type=audio",
        "GET /api/v1/books/fanqie/7304106523137952830/catalog?content_type=audio&page=1 / mode=full",
        "GET /api/v1/books/fanqie/7304106523137952830/chapters/7304589617225796658/audio?tone_id=1",
        "PUT /api/v1/reading/history (多次更新 progress)"
      ]
    },
    {
      "step": 18,
      "action": "切换平台到喜马拉雅，搜索 '剑来' 音频",
      "endpoint": "GET /api/v1/search?platform=ximalaya&q=%E5%89%91%E6%9D%A5&page=0&tab_type=2"
    },
    {
      "step": 19,
      "action": "检查搜索结果在书架状态，查看《剑来》上详情、目录，获取音频资源，更新阅读历史，多次更新进度（chapter_position 15,16）",
      "endpoints": [
        "POST /api/v1/shelf/status",
        "GET /api/v1/books/ximalaya/9724463?content_type=audio",
        "GET /api/v1/books/ximalaya/9724463/catalog?content_type=audio&page=1 / mode=full",
        "GET /api/v1/books/ximalaya/9724463/chapters/46189250/audio?tone_id=1",
        "PUT /api/v1/reading/history (多次)"
      ]
    },
    {
      "step": 20,
      "action": "最后查询配额和日志，确认配额消耗（fanqie used:5, ximalaya used:4）",
      "endpoints": [
        "GET /api/v1/quota",
        "GET /api/v1/quota/logs?page=1&size=20",
        "GET /api/v1/auth/profile",
        "GET /api/v1/platforms",
        "GET /api/v1/reading/history",
        "GET /api/v1/shelf",
        "GET /api/v1/announcements"
      ]
    }
  ],
  "api_endpoints": [
    { "method": "POST", "path": "/api/v1/auth/login", "purpose": "用户登录，获取JWT token" },
    { "method": "GET", "path": "/api/v1/auth/profile", "purpose": "获取当前用户资料" },
    { "method": "GET", "path": "/api/v1/announcements", "purpose": "获取公告列表" },
    { "method": "GET", "path": "/api/v1/platforms", "purpose": "获取支持的内容平台及其搜索标签" },
    { "method": "GET", "path": "/api/v1/reading/history", "purpose": "分页获取用户阅读历史" },
    { "method": "GET", "path": "/api/v1/reading/history/status", "purpose": "检查指定资源的阅读历史状态（进度等）" },
    { "method": "PUT", "path": "/api/v1/reading/history", "purpose": "更新或创建阅读进度记录" },
    { "method": "GET", "path": "/api/v1/shelf", "purpose": "分页获取用户书架" },
    { "method": "POST", "path": "/api/v1/shelf/status", "purpose": "批量检查一组资源是否在书架中" },
    { "method": "GET", "path": "/api/v1/search", "purpose": "跨平台搜索内容，query参数：platform, q, page, tab_type" },
    { "method": "GET", "path": "/api/v1/books/{platform}/{book_id}", "purpose": "获取书籍/有声书的详细信息" },
    { "method": "GET", "path": "/api/v1/books/{platform}/{book_id}/catalog", "purpose": "获取目录（分页或完整模式）" },
    { "method": "GET", "path": "/api/v1/books/{platform}/{book_id}/chapters/{chapter_id}", "purpose": "获取文本章节内容" },
    { "method": "GET", "path": "/api/v1/books/{platform}/{book_id}/chapters/{chapter_id}/audio?tone_id=1", "purpose": "获取音频章节的播放URL" },
    { "method": "GET", "path": "/api/v1/quota", "purpose": "获取用户各平台配额使用情况" },
    { "method": "GET", "path": "/api/v1/quota/logs", "purpose": "获取配额消耗日志" }
  ],
  "auth_analysis": {
    "type": "JWT Bearer Token",
    "credential_acquisition": "通过POST /api/v1/auth/login，使用email+password登录，响应中返回token字段。",
    "credential_storage": "登录成功后，token存入localStorage键'token'。",
    "credential_transmission": "后续API请求均在HTTP头中添加'authorization: Bearer <token>'。",
    "token_structure": {
      "header": { "alg": "HS256", "typ": "JWT" },
      "payload": {
        "auth_version": 1991602988539733978,
        "iss": "novelservices",
        "sub": "38a684ab-2674-47c0-b875-0707b3e68cd4",
        "aud": ["novelservices-web"],
        "exp": 1785247776,
        "iat": 1784988576
      },
      "signature": "ZL9CQ..."
    },
    "note": "未发现刷新token机制，无CSRF令牌。"
  },
  "streaming_analysis": null,
  "storage_analysis": {
    "localStorage": {
      "token": "JWT字符串",
      "novel-media-playback-rate": "1",
      "novel-media-volume-v2": "1"
    },
    "cookies": "无显著变化",
    "sessionStorage": "无记录"
  },
  "key_dependencies": {
    "token_flow": "登录 -> 存储token -> 后续所有请求携带Bearer token",
    "post_login": "获取announcements, platforms, reading_history, shelf, quota 等用于初始化界面",
    "search_flow": "选择platform -> 调用search -> 批量检查shelf/status -> 展示结果",
    "content_consumption": "点击书籍 -> 获取详情+目录 -> 获取章节内容/音频URL -> 更新阅读历史(进度上报)",
    "quota_tracking": "获取音频章节/文本内容会消耗配额(consume操作)，可通过quota/logs查看消耗记录"
  },
  "replay_instructions": [
    "1. 注册/登录：POST /api/v1/auth/login，携带email和password，获取Token。",
    "2. 初始化：使用Token请求/platforms, /announcements, /shelf, /reading/history, /auth/profile, /quota, /quota/logs。",
    "3. 搜索：GET /api/v1/search?platform=fanqie&q=关键词&page=0&tab_type=3 (3=小说，2=听书)。",
    "4. 搜索结果处理：提取book_id列表，POST /api/v1/shelf/status 检查是否已在书架。",
    "5. 打开书籍：GET /api/v1/books/{platform}/{book_id}?content_type=text/audio 获取详情。",
    "6. 获取目录：GET /api/v1/books/{platform}/{book_id}/catalog?content_type=...&page=1，可选mode=full获取全量目录。",
    "7. 阅读文本：GET /api/v1/books/{platform}/{book_id}/chapters/{chapter_id} 获取HTML内容。",
    "8. 收听音频：GET /api/v1/books/{platform}/{book_id}/chapters/{chapter_id}/audio?tone_id=1 获取音频URL。",
    "9. 进度上报：PUT /api/v1/reading/history，body包含platform, book_id, chapter_id, chapter_title, progress (百分比或秒?), chapter_position, chapter_total等。",
    "10. 播放过程中多次PUT progress更新（每隔一段时间）。",
    "11. 切换平台搜索类似。",
    "注意：所有请求Header需加 Authorization: Bearer <token>，Content-Type: application/json。"
  ],
  "notes": "该平台是一个聚合型小说和有声读物服务（NovelServices），整合了番茄小说、七猫、喜马拉雅等多个平台资源。用户通过搜索跨平台查询内容，可在线阅读文本或收听音频，系统以配额控制资源消耗。前端使用Anything Analyzer客户端(Electron应用模拟浏览器)。"
}
```