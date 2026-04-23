# Reminder CLI

CLI em Ruby para criar lembretes no macOS com notificacao nativa.

## Uso

```bash
./reminder add --text "Reuniao com cliente" --at "2026-04-23 15:00"
./reminder add --text "Sair para o medico" --at "2026-04-23 18:00" --warn 30m
./reminder list
./reminder remove <id>
```

## Formatos aceitos

- `--at`: `YYYY-MM-DD HH:MM` ou `YYYY-MM-DDTHH:MM`
- `--warn`:
  - `15` = 15 minutos
  - `15m` = 15 minutos
  - `2h` = 2 horas
  - `1d` = 1 dia

## Como funciona

- Salva os lembretes em `~/.reminder-cli/reminders.json`
- Cria `LaunchAgents` em `~/Library/LaunchAgents`
- Exibe a notificacao com `osascript`
- Usa `launchd`, `osascript`, `minitest` e `rubocop`

## Setup

```bash
bin/setup
```

## Qualidade

```bash
bin/lint
bin/test
```

## Pre-commit

O hook fica em `.githooks/pre-commit` e roda lint + tests.

Quando este diretório estiver em um repositorio Git:

```bash
git config core.hooksPath .githooks
```

## CI

O workflow fica em `.github/workflows/ci.yml` e executa lint + tests em `push` e `pull_request`.
