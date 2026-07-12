# Contributing

## Smoke tests

Перед PR по profile lock / profile skip логике запустите:

```bash
bash tests/profile_lock_smoke.sh
```

Тест работает только во временной директории в `/tmp`:

- не пишет в `/opt`;
- не запускает настоящий `zapret2`;
- проверяет `bash -n` для основных shell-файлов;
- проверяет persistent state: `auto` как отсутствие записи, `0`, `N`, `clear`;
- проверяет, что `locked.lua` содержит ветку `0 -> VERDICT_PASS`;
- проверяет повторное применение состояния к свежему `config`;
- проверяет `RKN`, `Discord TCP`, `VOICE UDP`, fallback TLS;
- проверяет, что `VOICE_UDP=0` убирает voice-порты из `NFQWS2_PORTS_UDP`;
- проверяет идемпотентность `profile_apply_all`.

Успешный результат:

```text
profile_lock smoke ok
```
