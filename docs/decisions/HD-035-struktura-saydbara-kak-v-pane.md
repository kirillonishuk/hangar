# HD-035 — 2026-10-18 — Структура сайдбара как в Pane:

«+ Новая задача», `ЗАКРЕПЛЁННЫЕ` (закреплённая задача показывается только там), слот `SSH HOSTS` (этап 6), `ПРОЕКТЫ` со сворачиваемыми группами (`Project.collapsed`), `АРХИВ N`; внизу настройки и «…». Модель: `HangarTask.pinned`, `Project.collapsed` (старые файлы читаются), мутации `setPinned`, `setProjectCollapsed`, `restoreTask`, `renameTask`, `renameProject`. Все действия над строками — в одном месте (`SidebarMenus`) для Task 6b. Почему: просьба пользователя. Отвергнуто: Sessions, Home/Feedback/Discord, отдельная кнопка Archive Tasks.
