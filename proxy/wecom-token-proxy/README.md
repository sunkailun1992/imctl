# wecom-token-proxy

imctl 的云端令牌注入代理（Java 17 / Spring Boot 4 / Maven）。契约见仓库 `docs/protocol/wecom-token-proxy.md`；它只做三件事：持 corp secret 并缓存 `access_token`、把白名单内的企微接口调用注入 token 转发、把企微回调验签解密后发布到 MQTT `wecom/{corpId}/evt`。不含业务、不落正文。

## 运行

所有参数来自环境变量（`src/main/resources/application.yml` 只列键名）：

```bash
export WECOM_CORP_ID=ww… WECOM_CORP_SECRET=… WECOM_AGENT_ID=… \
       WECOM_CALLBACK_TOKEN=… WECOM_CALLBACK_AES_KEY=… \
       PROXY_BEARER_TOKENS='<mac-01 的 token>,<mac-02 的 token>' \
       MQTT_URL='mqtt://<broker-host>:1883' MQTT_USERNAME=proxy MQTT_PASSWORD=… \
       PROXY_DATA_DIR=./data
mvn -q test                 # 单测：crypto 往返、token 缓存与重试、白名单、限流、序列持久化、回调中继、端到端 HTTP
mvn -q -DskipTests package && java -jar target/wecom-token-proxy-0.1.0.jar
curl -s localhost:8080/healthz
```

Docker：`docker build -t wecom-token-proxy . && docker run --env-file proxy.env -p 8080:8080 -v proxy-data:/app/data wecom-token-proxy`（`proxy.env` 不入库）。

## 端点

- `POST /wecom/{path}`：`Authorization: Bearer <token>`；`path` 须在白名单（默认 = imctl 用到的 16 个接口 + `media/upload`，`PROXY_ALLOWED_PATHS` 可覆盖）；企微响应原样返回；`401` / `404` / `429` / `502` / `503` 是代理自身状态。
- `GET|POST /wecom/callback`：企微"接收事件服务器"；验签失败 `403`，解密失败 `400`，发布失败 `500`（企微会重试），成功回 `success`。
- `GET /healthz`。

## 部署前提（用户提供）

固定公网 IP 主机（出口 IP 填自建应用"可信 IP"）、HTTPS 域名（反代终止 TLS 后转 8080）、自建应用参数、broker 上给代理的用户（发布 `wecom/+/evt`）。

## 结构

`config/`（属性记录与装配）、`auth/`（Bearer 过滤器、限流）、`token/`（WeCom HTTP 抽象、`RestClient` 实现、token 缓存）、`forward/`（白名单、转发、控制器）、`crypto/`（WXBizMsgCrypt）、`callback/`（XML 扁平化、中继、控制器）、`event/`（事件序列、发布接口、日志兜底）、`mqtt/`（HiveMQ MQTT 5 发布）。测试用 `FakeWeComHttp` 与记录式发布器，不连真实企微与 broker。
