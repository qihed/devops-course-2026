# VS Code vs терминал для работы с Git

## Что удобно в VS Code
1. Наглядный diff: изменения построчно видны в панели Source Control.
2. GitLens показывает автора и дату каждой строки (визуальный git blame).
3. Встроенный редактор конфликтов: кнопки Accept Current / Incoming / Both.

## Что удобнее в терминале
- Interactive rebase (`git rebase -i`), cherry-pick и reflog: IDE скрывает детали, а на сервере кроме терминала ничего не будет.
