INSERT INTO cloud_settings(key, value, updated_at, updated_by)
VALUES (
  'app_config',
  '{"appEnabled":true,"appDisabledMessage":"服务维护中，请稍后再试","subscriptionEnabled":true,"subscriptionDisabledMessage":"云端音源暂时停止更新"}',
  unixepoch(),
  'migration'
)
ON CONFLICT(key) DO NOTHING;
