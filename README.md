# Week 4 · Tasks 1 and 2 — Terraform + Ansible через AWS Systems Manager

## Задача

Поднять Terraform'ом инфраструктуру для Django-приложения [healthchecks](https://github.com/kaaalim/django-sample-app) — VPC, два сервера приложения и сервер базы в приватных подсетях, балансировщик — и настроить серверы тремя ролями Ansible, запущенными через AWS Systems Manager. Task 2 — свой модуль Ansible `django_configurator`, который пишет настройки подключения приложения к базе.

## Архитектура

```
                        интернет
                           │ 80
              ┌────────────▼────────────┐
              │  Application Load       │   публичные подсети
              │  Balancer               │   + NAT-шлюз
              └──────┬───────────┬──────┘
                     │ 80        │ 80
        ┌────────────▼──┐   ┌────▼──────────┐
        │ app-1         │   │ app-2         │   приватные подсети
        │ nginx         │   │ nginx         │   (две AZ)
        │ gunicorn      │   │ gunicorn      │
        └────────┬──────┘   └──────┬────────┘
                 │ 5432            │ 5432
              ┌──▼─────────────────▼──┐
              │ db: PostgreSQL 17     │
              └───────────────────────┘

  AWS Systems Manager ──State Manager──> Ansible на каждом сервере
  SSM Parameter Store ──> пароль базы, SECRET_KEY, адреса
  S3 ──> плейбуки для SSM, логи запусков
```

## Что развёрнуто

| Компонент | Как сделано |
|---|---|
| Сеть | VPC `10.60.0.0/16`, по две публичные и приватные подсети в разных AZ, интернет-шлюз, один NAT-шлюз |
| Серверы | 3 × `t3.micro`, Amazon Linux 2023 (SSM Agent предустановлен), IMDSv2 обязателен, диски зашифрованы, публичных IP нет |
| Security groups | цепочка ALB → app → db, правила ссылаются на группы, а не на адреса. SSH не открыт нигде |
| Балансировщик | ALB, health check `/api/v3/status/` — эндпоинт приложения, который делает `SELECT 1` в базе |
| IAM | роль инстансов: `AmazonSSMManagedInstanceCore` + чтение и запись одного бакета + чтение параметров одного префикса |
| Секреты | пароль базы и `SECRET_KEY` генерирует Terraform (`random_password`) и кладёт в Parameter Store как `SecureString` |
| Запуск Ansible | 3 ассоциации State Manager на документе `AWS-ApplyAnsiblePlaybooks` |
| Инвентарь | `ansible/inventory.ini` генерирует Terraform: хосты по ID инстансов, подключение `amazon.aws.aws_ssm` |
| Роли | `postgres-setup`, `webserver-setup`, `deploy` |
| Task 2 | модуль `ansible/library/django_configurator.py` |

## Структура репозитория

```
├── ansible
│   ├── db.yml                    плейбук сервера базы
│   ├── webservers.yml            плейбук подготовки серверов приложения
│   ├── deploy.yml                плейбук выката, serial: 1
│   ├── inventory.ini             генерирует Terraform
│   ├── library
│   │   └── django_configurator.py   Task 2
│   └── roles
│       ├── postgres-setup        PostgreSQL, пользователь, база, pg_hba
│       ├── webserver-setup       Python 3.12, venv, пользователь, nginx
│       └── deploy                код, зависимости, настройки, миграции, запуск
│           ├── files/nginx.conf
│           ├── templates/app.env.j2
│           ├── templates/django.service.j2   сверх схемы: юнит systemd
│           └── values/main.yml   подключается явно через include_vars
└── terraform
    ├── providers.tf              версии, backend S3, данные AMI
    ├── variables.tf
    ├── vpc.tf
    ├── ec2.tf                    security groups и инстансы
    ├── alb.tf
    ├── iam.tf
    ├── ssm.tf                    бакет, Parameter Store, ассоциации State Manager
    ├── outputs.tf                выходы и генерация inventory.ini
    └── terraform.tfvars          enable_ssm_associations = true
```

Каждый ресурс в `.tf` отделён рамкой `################` с его адресом, группы ресурсов — широкими заголовками с пояснениями.

## Как запустить

**Нужно:** Terraform ≥ 1.10, AWS CLI v2, `session-manager-plugin`, `ansible-core` с коллекциями `amazon.aws` и `community.postgresql`, библиотеки `boto3` и `botocore` в том Python, которым работает Ansible, и AWS-ключи с правами администратора в текущем терминале.

Backend состояния — S3-бакет из `terraform/providers.tf`. Для своего аккаунта замени имя бакета или удали блок `backend`.

**1. Инфраструктура без ассоциаций** — сначала серверы должны появиться в Systems Manager:

```bash
cd terraform && terraform init && terraform apply -var enable_ssm_associations=false
```

**2. Проверить, что все три сервера видны в Systems Manager** (через 1–3 минуты после apply):

```bash
aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output text
```

Ожидаем три строки `Online`.

**3. Ассоциации State Manager** — `terraform.tfvars` включает их:

```bash
terraform apply
```

Apply идёт 10–30 минут: Terraform ждёт, пока каждый сервер сам поставит Ansible и прогонит плейбуки — сначала `db.yml` и `webservers.yml`, потом `deploy.yml` по одному серверу.

**4. Проверить приложение:**

```bash
curl -s "http://$(terraform output -raw alb_dns_name)/accounts/login/" | grep -o '<title>[^<]*'
```

Ожидаем `<title>Log In - Week 4 Healthchecks`.

**5. Создать пользователя.** Почта не настроена, поэтому регистрация по ссылке из письма не работает — пользователь создаётся командой приложения на любом сервере приложения. ID серверов:

```bash
terraform output app_instance_ids
```

Открыть сессию на любом из них, подставив ID:

```bash
aws ssm start-session --target i-0123456789abcdef0
```

Внутри сессии — команда спросит email и пароль:

```bash
sudo -u django bash -c 'cd /opt/django-sample-app/src && set -a && . ../app.env && set +a && ../venv/bin/python manage.py createsuperuser'
```

**6. Удалить всё:**

```bash
terraform destroy
```

Проверенный путь — два apply, как выше. Запуск с нуля одним `terraform apply` с включёнными ассоциациями не проверялся.

**Ручной запуск ролей для отладки** — с машины через инвентарь из Terraform, без SSH:

```bash
cd ansible && ansible -i inventory.ini all -m ping
```

```bash
ansible-playbook -i inventory.ini deploy.yml --limit webservers
```

## Три роли

| Роль | Хосты | Что делает | Как часто меняется |
|---|---|---|---|
| `postgres-setup` | `Role=db` | PostgreSQL 17, пользователь и база, доступ только из подсетей приложения | раз за жизнь сервера |
| `webserver-setup` | `Role=app` | Python 3.12, `git`, `libpq`, пользователь `django`, venv, nginx | раз за жизнь сервера |
| `deploy` | `Role=app` | код, зависимости, `local_settings.py`, миграции, gunicorn, конфиг nginx | каждый релиз |

Роли разделены по частоте изменений: первые две описывают состояние машины, третья — версию приложения. Подробности, входы и ограничения — в README каждой роли.

## Как роли запускаются через SSM

Три ассоциации State Manager на документе `AWS-ApplyAnsiblePlaybooks`. Документ скачивает каталог `ansible/` из S3 на сервер, ставит Ansible через `pip` и запускает `ansible-playbook -i "localhost," -c local` — **каждый сервер настраивает сам себя**. Поэтому в плейбуках `hosts: all`, а какой плейбук где выполнять, определяет цель ассоциации по тегу `Role`.

| Ассоциация | Плейбук | Цель | `max_concurrency` | `max_errors` |
|---|---|---|---|---|
| `week4-dev-db` | `db.yml` | `tag:Role=db` | 1 | 0 |
| `week4-dev-webservers` | `webservers.yml` | `tag:Role=app` | 2 | 0 |
| `week4-dev-deploy` | `deploy.yml` | `tag:Role=app` | **1** | 0 |

**Порядок.** Ассоциация запускает плейбук сразу при создании, но Terraform считает её созданной, как только ответил API, — обычный `depends_on` порядок не гарантирует. С `wait_for_success_timeout_seconds` Terraform ждёт статус `Success`, а ассоциация `deploy` зависит от базовых и создаётся только после их успеха. Проверено по времени: `db` и `webservers` стартовали в 08:24:17 и завершились к 08:25:25, `deploy` создана в 08:25:31, серверы обновились в 08:26:03 и 08:26:34 — строго по очереди.

**Повторные запуски.** Ожидание работает только при создании ассоциации, а правка файла роли в S3 ассоциацию не меняет. Поэтому у каждой ассоциации `replace_triggered_by` на ресурс `terraform_data` с хешем файлов своего плейбука, параметров, ID целевых серверов и версий нужных параметров Parameter Store. Поправил роль `deploy` → `terraform apply` → пересоздаётся только ассоциация `deploy`, с ожиданием и в правильном порядке. Повторный `terraform plan` без изменений пустой.

**Секреты не передаются параметрами документа.** У параметра `ExtraVariables` есть `allowedPattern`, запрещающий `| : ( ) ; &` и пробелы внутри значения, а параметры ассоциации видны в консоли. Через него идут только `ssm_param_prefix`, `aws_region`, `app_version`, `deployment_environment`; остальное роли читают из Parameter Store на сервере.

**Два способа запуска.** State Manager — основной, его требует задание. Плагин `amazon.aws.aws_ssm` с машины разработчика — для отладки ролей: тот же Systems Manager вместо SSH, но итерация за секунды, а не минуты. Инвентарь из Terraform используется именно этим способом.

## Миграции на двух серверах

Серверов приложения два, база одна, межпроцессной блокировки миграций в Django нет. Выбран **выкат по одному серверу**: первый применяет миграции, на втором `migrate` печатает `No migrations to apply`.

- через SSM — `max_concurrency = "1"` у ассоциации `deploy`
- с машины — `serial: 1` в `deploy.yml`

`run_once` не подходит: через SSM каждый сервер запускает плейбук для себя и соседа не видит. Флаг `run_migrations=true` для одного сервера отвергнут: пересоздали этот сервер — миграции тихо перестали выполняться. `max_errors = "0"` останавливает выкат на первой ошибке, остальные серверы остаются на старой версии. Следствие — миграции должны быть обратно совместимыми.

## Task 2 — модуль `django_configurator`

**Генерирует `hc/local_settings.py`, а не правит `settings.py`.** Задание говорит «generate or modify the settings.py file», но `settings.py` приходит из git — правка конфликтовала бы с каждым обновлением кода. У приложения есть штатная точка расширения: последние строки `settings.py` подключают `local_settings.py`, если он существует. Модуль собирает содержимое этого файла целиком и сравнивает с диском — отсюда идемпотентность.

**Входы:** `environment`, `db_host`, `db_name`, `db_user`, `db_password`, `additional_settings` из задания, плюс `project_path` (модуль выполняется на сервере и не знает, где проект), `allowed_hosts`, `db_port`, `settings_package` и стандартные `owner`, `group`, `mode`. Без `mode` файл получает `0600`: в нём пароль.

**Выходы:** `message` — печатается задачей из задания; `changes` — отчёт `{added, removed, modified}` с **именами** настроек, значения не возвращаются никогда.

**Ошибки:** нет каталога проекта; нет `settings.py`; `settings.py` не подключает `local_settings` (сгенерированный файл был бы проигнорирован); пустые реквизиты; порт вне диапазона; production без `allowed_hosts`; настройка в нижнем регистре; попытка задать `DEBUG`, `ALLOWED_HOSTS` или `DATABASES` через `additional_settings`; нет прав на запись. В production с `ALLOWED_HOSTS = ['*']` — предупреждение.

**Как проверено:**

- 37 функциональных проверок запуском модуля так, как его запускает Ansible — JSON на stdin: создание, идемпотентность, check mode, diff, изменение и удаление настроек, права файла, все ветки ошибок
- в `--diff` пароль заменён на `********`, в ответах модуля пароля нет
- `ansible-doc` разбирает документацию, синтаксис совместим с Python 3.9 — системным Python серверов
- на серверах через SSM: `Django settings in /opt/django-sample-app/src/hc/local_settings.py are already up to date`, отчёт изменений пустой
- на странице входа название `Week 4 Healthchecks` из `additional_settings` — значит файл реально подключается

Вызов модуля стоит в `ansible/roles/deploy/tasks/main.yml` после обновления кода и до миграций: `migrate` подключается к базе по настройкам, которые пишет модуль.

## Как проверено

| Проверка | Результат |
|---|---|
| серверы в Systems Manager | 3 × `Online` |
| ассоциации State Manager | 3 × `Success`, в логах всех плейбуков `failed=0` |
| повторный `terraform plan` | `No changes` |
| идемпотентность ролей (запуск через SSM на настроенных серверах) | `postgres-setup` ok=10 changed=0, `webserver-setup` ok=7 changed=0, `deploy` ok=17 changed=0 |
| цели балансировщика | обе `healthy` |
| приложение через ALB | `/accounts/login/` и `/api/v3/status/` — 200, CSS и JS из `compress` — 200 |
| распределение нагрузки | 10 запросов: 4 на один сервер, 6 на другой |
| база | 205 применённых миграций, 23 таблицы, владелец `hc`, файлов SQLite на серверах нет |
| что видит Django | `postgresql`, `DEBUG=False`, настройки из `local_settings.py` |
| секреты в логах SSM | пароля базы и `SECRET_KEY` нет ни в одном файле (поиск по настоящим значениям) |
| версия Ansible, которую поставил SSM | `ansible 8.7.0` / `ansible-core 2.15.13` |

## Что пошло не так

**`ExtraVariables` не принимает URL.** Первая версия передавала адрес репозитория в `ExtraVariables`. Содержимое документа (`aws ssm get-document`) показало `allowedPattern`, запрещающий двоеточие даже в кавычках, — ассоциация упала бы на `terraform apply`. URL, адрес ALB и реквизиты перенесены в Parameter Store.

**Health check на `/` никогда не стал бы зелёным.** Главная страница для анонимного пользователя отдаёт 302 на страницу входа. Используется `/api/v3/status/` — он ещё и проверяет базу.

**Системный Python не подходит приложению.** На Amazon Linux 2023 Python 3.9, а Django 6.1 требует ≥ 3.12. Приложение работает в venv на `python3.12` из репозитория, Ansible — на системном 3.9.

**`git clone` в непустой каталог.** Заготовка клала venv внутрь каталога кода — клонирование упало бы. Код и окружение разнесены: `/opt/django-sample-app/src` и `/opt/django-sample-app/venv`.

**`depends_on` не ждёт плейбук.** Ассоциации создавались параллельно, и `deploy` мог стартовать раньше, чем появится PostgreSQL. Решено так: `wait_for_success_timeout_seconds` заставляет Terraform ждать статус `Success`, а `replace_triggered_by` пересоздаёт ассоциацию при изменении роли, чтобы ожидание срабатывало и на повторных запусках.

**Check mode врал.** В `--check` Ansible пропускает `command`, включая задачу, которая только читает Parameter Store; шаблоны дальше рендерились с пустыми значениями и показывали ложный `changed`. Читающие задачи получили `check_mode: false`.

**Инвентарь с отступами.** Шаблон `%{for}` внутри heredoc `<<-` не срезал отступ, строки хостов уезжали на 4 пробела. Проверено рендером на тестовых данных, заменено на `join`.

**Подсказки заготовки не совпали с реальностью.** `psycopg2-binary` через pip в системный Python, `gcc` и `libcurl-devel` «для сборки `pycurl`» — проверка по PyPI показала готовые wheel для всех C-зависимостей, а драйвер для модулей Ansible есть пакетом `python3-psycopg2`.

**`Unable to locate credentials` при ручном запуске.** Плагин `aws_ssm` работает на машине разработчика и падает на первой задаче, если в терминале не подключены AWS-ключи.

## Что осталось незакрытым

| Пробел | Почему так | Что было бы в production |
|---|---|---|
| HTTP без TLS | нет домена и сертификата | ACM-сертификат, слушатель 443, редирект с 80 |
| один NAT-шлюз | стоимость учебного стенда | NAT в каждой AZ |
| PostgreSQL на EC2, без бэкапов и реплик | требование задания | RDS Multi-AZ со снапшотами |
| выкат без снятия сервера с балансировщика | простота | вывод цели из target group на время выката или blue/green |
| нет отката релиза | простота | каталоги релизов с переключением симлинка или образы |
| версия Ansible на серверах не закреплена | `InstallDependencies` ставит последнюю совместимую | свой SSM-документ или AMI с закреплённой версией |
| выкатывается ветка `main` | учебный стенд | тег или коммит |
| деплой запускается `terraform apply` | одна точка входа для стенда | CI вызывает `aws ssm start-associations-once` |
| секреты есть в state Terraform | так работает `random_password` | state в S3 зашифрован и закрыт IAM; секреты с ротацией в Secrets Manager |
| `manage.py sendalerts` не запущен | задание не требует | вторая systemd-служба |
| регистрация открыта (`REGISTRATION_OPEN`) | без почты её не завершить | `REGISTRATION_OPEN: false` через `additional_settings` |
| `pg_hba.conf` не очищается от убранных подсетей | роль только добавляет правила | `state: absent` для устаревших правил |

---

> Ниже — исходный README приложения healthchecks.

# Healthchecks

[![Tests](https://example.com/repo/actions/workflows/tests.yml/badge.svg)](https://example.com/repo/actions/workflows/tests.yml)
[![Coverage Status](https://coveralls.io/repos/example/repo/badge.svg?branch=master&service=github)](https://coveralls.io/github/example/repo?branch=master)

Healthchecks is a cron job monitoring service. It listens for HTTP requests
and email messages ("pings") from your cron jobs and scheduled tasks ("checks").
When a ping does not arrive on time, Healthchecks sends out alerts.

Healthchecks comes with a web dashboard, API, 25+ integrations for
delivering notifications, monthly email reports, WebAuthn 2FA support,
team management features: projects, team members, read-only access.

The building blocks are:

* Python 3.12+
* Django 6.1
* PostgreSQL, MySQL or MariaDB

Healthchecks is licensed under the BSD 3-clause license.

Healthchecks is available as a hosted service
at [https://healthchecks.io/](https://healthchecks.io/).

Screenshots:

The "My Checks" screen. Shows the status of all your cron jobs
in a live-updating dashboard.

![Screenshot of My Checks page](/static/img/my_checks.png?raw=true "My Checks Page")

Each check has configurable Period and Grace Time parameters. Period is the expected
time between pings. Grace Time specifies how long to wait before sending out alerts
when a job is running late.

![Screenshot of Period/Grace dialog](/static/img/period_grace.png?raw=true "Period/Grace Dialog")

Alternatively, you can define the expected schedules using a cron expressions.
Healthchecks uses the [cronsim](https://github.com/cuu508/cronsim) library to
parse and evaluate cron expressions.

![Screenshot of Cron dialog](/static/img/cron.png?raw=true "Cron Dialog")

Check details page, with a live-updating event log.

![Screenshot of Check Details page](/static/img/check_details.png?raw=true "Check Details Page")

Healthchecks provides status badges with public but hard-to-guess URLs.
You can use them in your READMEs, dashboards, or status pages.

![Screenshot of Badges page](/static/img/badges.png?raw=true "Status Badges")


## Setting Up for Development

If you are planning to developing Healthchecks, please read
[CONTRIBUTING.md](https://example.com/repo/tree/master/CONTRIBUTING.md).

To set up Healthchecks development environment:

* Install dependencies (Debian/Ubuntu):

  ```sh
  sudo apt update
  sudo apt install -y gcc python3-dev python3-venv libpq-dev libcurl4-openssl-dev libssl-dev
  ```

* Prepare directory for project code and virtualenv. Feel free to use a
  different location:

  ```sh
  mkdir -p ~/webapps
  cd ~/webapps
  ```

* Prepare virtual environment
  (with virtualenv you get pip, we'll use it soon to install requirements):

  ```sh
  python3 -m venv .venv
  source .venv/bin/activate
  pip3 install wheel # make sure wheel is installed in the venv
  ```

* Check out project code:

  ```sh
  git clone https://example.com/repo.git
  ```

* Install requirements (Django, ...) into virtualenv:

  ```sh
  pip install -r healthchecks/requirements.txt -r healthchecks/requirements-dev.txt
  ```

* macOS only - pycurl needs to be reinstalled using the following method (assumes OpenSSL was installed using brew):

  ```sh
  export PYCURL_VERSION=`cat requirements.txt | grep pycurl | cut -d '=' -f3`
  export OPENSSL_LOCATION=`brew --prefix openssl`
  export PYCURL_SSL_LIBRARY=openssl
  export LDFLAGS=-L$OPENSSL_LOCATION/lib
  export CPPFLAGS=-I$OPENSSL_LOCATION/include
  pip uninstall -y pycurl
  pip install pycurl==$PYCURL_VERSION --compile --no-cache-dir
  ```

* Create database tables and a superuser account:

  ```sh
  cd ~/webapps/healthchecks
  ./manage.py migrate
  ./manage.py createsuperuser
  ```

  With the default configuration, Healthchecks stores data in a SQLite file
  `hc.sqlite` in the checkout directory (`~/webapps/healthchecks`).

* Run tests:

  ```sh
  ./manage.py test
  ```

* Run development server:

  ```sh
  ./manage.py runserver
  ```

The site should now be running at `http://localhost:8000`.
To access Django administration site, log in as a superuser, then
visit `http://localhost:8000/admin/`

## Configuration

Healthchecks reads configuration from environment variables. See the
[full list of configuration parameters](https://healthchecks.io/docs/self_hosted_configuration/)
you can set via environment variables.

In addition, Healthchecks reads settings from the `hc/local_settings.py` file if it
exists. You can set or override any [standard Django setting](https://docs.djangoproject.com/en/6.1/ref/settings/)
in this file. You can copy the provided `hc/local_settings.py.example` as
`hc/local_settings.py` and use it as a starting point.

If a setting is specified both as environment variable and in `hc/local_settings.py`,
the latter takes precedence.

## Accessing Administration Panel

Healthchecks comes with Django's administration panel where you can perform
administrative tasks: delete user accounts, change passwords, increase limits for
specific users, inspect contents of database tables.

To access the administration panel,

 * if you haven't already, create a superuser account: `./manage.py createsuperuser`
 * log into the site using superuser credentials
 * in the top navigation, "Account" dropdown, select "Site Administration"


## Sending Emails

Healthchecks must be able to send email messages, so it can send out login
links and alerts to users. Specify your SMTP credentials using the following
environment variables:

- Implicit TLS (*recommended*):
    ```python
    DEFAULT_FROM_EMAIL = "valid-sender-address@example.org"
    EMAIL_HOST = "smtp.example.org"
    EMAIL_PORT = 465
    EMAIL_HOST_USER = "example-username"
    EMAIL_HOST_PASSWORD = "example-password"
    EMAIL_USE_TLS = False
    EMAIL_USE_SSL = True
    ```

    Port 465 should be the preferred method according to [RFC8314 Section 3.3: Implicit
    TLS for SMTP Submission](https://tools.ietf.org/html/rfc8314#section-3.3). Be sure
    to use a TLS certificate and not an SSL one.

- Explicit TLS:
    ```python
    DEFAULT_FROM_EMAIL = "valid-sender-address@example.org"
    EMAIL_HOST = "smtp.example.org"
    EMAIL_PORT = 587
    EMAIL_HOST_USER = "example-username"
    EMAIL_HOST_PASSWORD = "example-password"
    EMAIL_USE_TLS = True
    ```

Healthchecks use these environment variables to construct the `settings.MAILERS`
dictionary (a standard Django setting, [docs](https://docs.djangoproject.com/en/6.1/ref/settings/#std-setting-MAILERS)).

## Receiving Emails

Healthchecks comes with a `smtpd` management command, which starts up a
SMTP listener service. With the command running, you can ping your
checks by sending email messages
to `your-uuid-here@my-monitoring-project.com` email addresses.

Start the SMTP listener on port 2525:

```sh
./manage.py smtpd --port 2525
```

Send a test email:

```sh
curl --url 'smtp://127.0.0.1:2525' \
    --mail-from 'foo@example.org' \
    --mail-rcpt '11111111-1111-1111-1111-111111111111@my-monitoring-project.com' \
    -F '='
```

## Sending Alerts and Reports

Healthchecks comes with a `sendalerts` management command, which continuously
polls database for any checks changing state, and sends out notifications as
needed. Within an activated virtualenv, you can manually run
the `sendalerts` command like so:

```sh
./manage.py sendalerts
```

In a production setup, you will want to run this command from a process
manager like systemd or [supervisor](http://supervisord.org/).

Healthchecks also comes with a `sendreports` management command which
sends out monthly reports, weekly reports, and the daily or hourly reminders.

Run `sendreports` without arguments to run any due reports and reminders
and then exit:

```sh
./manage.py sendreports
```

Run it with the `--loop` argument to make it run continuously:

```sh
./manage.py sendreports --loop
```

## Database Cleanup

Healthchecks deletes old entries from `api_ping`, `api_flip`, and `api_notification`
tables automatically. By default, Healthchecks keeps the 100 most recent
pings for every check. You can set the limit higher to keep a longer history:
go to the Administration Panel, look up user's **Profile** and modify its
"Ping log limit" field.

Healthchecks also provides management commands for cleaning up
`auth_user` (user accounts) and `api_tokenbucket` (rate limiting records) tables,
and for removing stale objects from external object storage.

* Remove user accounts that are older than 1 month and have never logged in:

  ```sh
  ./manage.py pruneusers
  ```

* Remove old records from the `api_tokenbucket` table. The TokenBucket
  model is used for rate-limiting login attempts and similar operations.
  Any records older than one day can be safely removed.

  ```sh
  ./manage.py prunetokenbucket
  ```

* Remove old objects from external object storage. When an user removes
  a check, removes a project, or closes their account, Healthchecks
  does not remove the associated objects from the external object
  storage on the fly. Instead, you should run `pruneobjects` occasionally
  (for example, once a month). This command first takes an inventory
  of all checks in the database, and then iterates over top-level
  keys in the object storage bucket, and deletes any that don't also
  exist in the database.

  ```sh
  ./manage.py pruneobjects
  ```

When you first try these commands on your data, it is a good idea to
test them on a copy of your database, not on the live database right away.
In a production setup, you should also have regular, automated database
backups set up.

## Two-factor Authentication

Healthchecks optionally supports two-factor authentication using the WebAuthn
standard. To enable WebAuthn support, set the `RP_ID` (relying party identifier )
setting to a non-null value. Set its value to your site's domain without scheme
and without port. For example, if your site runs on `https://my-hc.example.org`,
set `RP_ID` to `my-hc.example.org`.

## External Authentication

Healthchecks supports external authentication by means of HTTP headers set by
reverse proxies or the WSGI server. This allows you to integrate it into your
existing authentication system (e.g., LDAP or OAuth) via an authenticating proxy.
When this option is enabled, **healthchecks will trust the header's value implicitly**,
so it is **very important** to ensure that attackers cannot set the value themselves
(and thus impersonate any user). How to do this varies by your chosen proxy,
but generally involves configuring it to strip out headers that normalize to the
same name as the chosen identity header.

To enable this feature, set the `REMOTE_USER_HEADER` value to a header you wish to
authenticate with. HTTP headers will be prefixed with `HTTP_` and have any dashes
converted to underscores. Headers without that prefix can be set by the WSGI server
itself only, which is more secure.

When `REMOTE_USER_HEADER` is set, Healthchecks will:
 - assume the header contains user's email address
 - look up and automatically log in the user with a matching email address
 - automatically create an user account if it does not exist
 - disable the default authentication methods (login link to email, password)

The header name in `REMOTE_USER_HEADER` must be specified in upper-case,
with any dashes replaced with underscores, and prefixed with `HTTP_`. For
example, if your authentication proxy sets a `X-Authenticated-User` request
header, you should set `REMOTE_USER_HEADER=HTTP_X_AUTHENTICATED_USER`.

**Note on using `local_settings.py`:**
When Healthchecks reads settings from environment variables and encounters
the `REMOTE_USER_HEADER` environment variable, it sets *two* settings,
`REMOTE_USER_HEADER` and `AUTHENTICATION_BACKENDS`. This logic has already run by the
time Healthchecks reads `local_settings.py`. Therefore, if you configure Healthchecks
using the `local_settings.py` file instead of environment variables, and specify
`REMOTE_USER_HEADER` there, you will also need a line which sets the other setting,
`AUTHENTICATION_BACKENDS`:

```
REMOTE_USER_HEADER = "HTTP_X_AUTHENTICATED_USER"
AUTHENTICATION_BACKENDS = ["hc.accounts.backends.CustomHeaderBackend"]
```

## External Object Storage

Healthchecks can optionally store large ping bodies in S3-compatible object
storage. To enable this feature, you will need to:

* ensure you have the [MinIO Python library](https://docs.min.io/docs/python-client-quickstart-guide.html) installed:

  ```bash
  pip install minio
  ```
* configure the credentials for accessing object storage: `S3_ACCESS_KEY`,
  `S3_SECRET_KEY`, `S3_ENDPOINT`, `S3_REGION` and `S3_BUCKET`.

Healthchecks will use external object storage for storing any request bodies that
exceed 100 bytes. If the size of a request body is 100 bytes or below, Healthchecks
will still store it in the database.

Healthchecks automatically removes old stored ping bodies from object
storage while uploading new data. However, Healthchecks does not automatically
clean up data when you delete checks, projects or entire user accounts.
Use the `pruneobjects` management command to remove data for checks that don't
exist any more.

When external object storage is not enabled (the credentials for accessing object
storage are not set), Healthchecks stores all ping bodies in the database.
If you enable external object storage, Healthchecks will still be able to
access the ping bodies already stored in the database. You don't need to migrate
them to the object storage. On the other hand, if you later decide to disable
external object storage, Healthchecks will not have access to the externally
stored ping bodies any more. And there is currently no script or management command
for migrating ping bodies from external object storage back to the database.

## Integrations

### Slack

Healthchecks supports two Slack integration setup flows: legacy and app-based.

The legacy flow does not require additional configuration and is used by default.
In this flow the user creates an incoming webhook URL on the Slack side, and
pastes the webhook URL in a form on the Healthchecks side.

In the app-based flow the user clicks an "Add to Slack" button in Healthchecks,
and gets transferred to a Slack-hosted dialog where they select the channel to
post notifications to. This flow uses OAuth2 behind the scenes. To enable this
flow, you will need to set up a Slack OAuth2 app:

* Create a new Slack app on https://api.slack.com/apps/
* Add at least one scope in the permissions section to be able to deploy the app in
  your workspace (By example `incoming-webhook` for the `Bot Token Scopes`).
* Add a _redirect url_ in the format `SITE_ROOT/integrations/add_slack_btn/`.
  For example, if your SITE_ROOT is `https://my-hc.example.org` then the redirect URL
  would be `https://my-hc.example.org/integrations/add_slack_btn/`.
* Look up your Slack app for the Client ID and Client Secret. Put them
  in `SLACK_CLIENT_ID` and `SLACK_CLIENT_SECRET` environment
  variables. Once these variables are set, Healthchecks will switch from using
  the legacy flow to using the app-based flow.

The legacy and app-based flows only affect the user experience during the initial
setup of Slack integrations. The contents of notifications posted to Slack are the same
regardless of the setup flow used.

### Discord

To enable Discord integration, you will need to:

* register a new application on https://discord.com/developers/applications/me
* add a redirect URI to your Discord application. The URI format is
  `SITE_ROOT/integrations/add_discord/`. For example, if you are running a
  development server on `localhost:8000` then the redirect URI would be
  `http://localhost:8000/integrations/add_discord/`
* Look up your Discord app's Client ID and Client Secret. Put them
  in `DISCORD_CLIENT_ID` and `DISCORD_CLIENT_SECRET` environment
  variables.


### Pushover

Pushover integration works by creating an application on Pushover.net which
is then subscribed to by Healthchecks users. The registration workflow is as follows:

* On Healthchecks, the user adds a "Pushover" integration to a project
* Healthchecks redirects user's browser to a Pushover.net subscription page
* User approves adding the Healthchecks subscription to their Pushover account
* Pushover.net HTTP redirects back to Healthchecks with a subscription token
* Healthchecks saves the subscription token and uses it for sending Pushover
  notifications

To enable the Pushover integration, you will need to:

* Register a new application on Pushover via https://pushover.net/apps/build.
* Within the Pushover 'application' configuration, enable subscriptions.
  Make sure the subscription type is set to "URL". Also make sure the redirect
  URL is configured to point back to the root of the Healthchecks instance
  (e.g., `http://healthchecks.example.com/`).
* Put the Pushover application API Token and the Pushover subscription URL in
  `PUSHOVER_API_TOKEN` and `PUSHOVER_SUBSCRIPTION_URL` environment
  variables. The Pushover subscription URL should look similar to
  `https://pushover.net/subscribe/yourAppName-randomAlphaNumericData`.

### Signal

Healthchecks uses [signal-cli](https://github.com/AsamK/signal-cli) to send Signal
notifications. Healthcecks interacts with signal-cli over UNIX or TCP socket.
Healthchecks requires signal-cli version 0.11.2 or later.

To enable the Signal integration via UNIX socket:

* Set up and configure signal-cli to expose JSON RPC on an UNIX socket
  ([instructions](https://github.com/AsamK/signal-cli/wiki/JSON-RPC-service)).
  Example: `signal-cli -a +xxxxxx daemon --socket /tmp/signal-cli-socket`
* Put the socket's location in the `SIGNAL_CLI_SOCKET` environment variable.

To enable the Signal integration via TCP socket:

* Set up and configure signal-cli to expose JSON RPC on a TCP socket.
  Example: `signal-cli -a +xxxxxx daemon --tcp 127.0.0.1:7583`
* Put the socket's hostname and port in the `SIGNAL_CLI_SOCKET` environment variable
  using "hostname:port" syntax, example: `127.0.0.1:7583`.


### Telegram

* Create a Telegram bot by talking to the
[BotFather](https://core.telegram.org/bots#6-botfather). Set the bot's name,
description, user picture, and add a "/start" command. To avoid user confusion,
please do not use the Healthchecks.io logo as your bot's user picture, use
your own logo.
* After creating the bot you will have the bot's name and token. Put them
in `TELEGRAM_BOT_NAME` and `TELEGRAM_TOKEN` environment variables.
* Run `settelegramwebhook` management command. This command tells Telegram
where to forward channel messages by invoking Telegram's
[setWebhook](https://core.telegram.org/bots/api#setwebhook) API call:

    ```sh
    ./manage.py settelegramwebhook
    Done, Telegram's webhook set to: https://my-monitoring-project.com/integrations/telegram/bot/
    ```

For this to work, your `SITE_ROOT` must be correct and must use the "https://"
scheme.

### Apprise

To enable Apprise integration, you will need to:

* ensure you have apprise installed in your local environment:

  ```bash
  pip install apprise
  ```
* enable the apprise functionality by setting the `APPRISE_ENABLED` environment variable.

### Shell Commands

The "Shell Commands" integration runs user-defined local shell commands when checks
go up or down. This integration is disabled by default, and can be enabled by setting
the `SHELL_ENABLED` environment variable to `True`.

Note: be careful when using "Shell Commands" integration, and only enable it when
you fully trust the users of your Healthchecks instance. The commands will be executed
by the `manage.py sendalerts` process, and will run with the same system permissions as
the `sendalerts` process.

### Matrix

To enable the Matrix integration you will need to:

* Register a bot user (for posting notifications) in your preferred homeserver.
* Use the [Login API call](https://www.matrix.org/docs/guides/client-server-api#login)
  to retrieve bot user's access token. You can run it as shown in the documentation,
  using curl in command shell.
* Set the `MATRIX_` environment variables. Example:

```
MATRIX_HOMESERVER=https://matrix.org
MATRIX_USER_ID=@mychecks:matrix.org
MATRIX_ACCESS_TOKEN=[a long string of characters returned by the login call]
```

### PagerDuty Simple Install Flow

To enable PagerDuty [Simple Install Flow](https://developer.pagerduty.com/docs/app-integration-development/events-integration/),

* Register a PagerDuty app at [PagerDuty](https://pagerduty.com/) › Developer Mode › My Apps
* In the newly created app, add the "Events Integration" functionality
* Specify a Redirect URL: `https://your-domain.com/integrations/add_pagerduty/`
* Copy the displayed app_id value (PXXXXX) and put it in the `PD_APP_ID` environment
  variable

## Running in Production

Here is a non-exhaustive list of pointers and things to check before launching a
Healthchecks instance in production.

* Environment variables, settings.py and local_settings.py.
  * [DEBUG](https://docs.djangoproject.com/en/6.1/ref/settings/#debug). Make sure it is
    set to `False`.
  * [ALLOWED_HOSTS](https://docs.djangoproject.com/en/6.1/ref/settings/#allowed-hosts).
    Make sure it contains the correct domain name you want to use.
  * Server Errors. When DEBUG=False, Django will not show detailed error pages, and
    will not print exception tracebacks to standard output. To receive exception
    tracebacks in email, review and edit the
    [ADMINS](https://docs.djangoproject.com/en/6.1/ref/settings/#admins) and
    [SERVER_EMAIL](https://docs.djangoproject.com/en/6.1/ref/settings/#server-email)
    settings. Consider setting up exception logging with [Sentry](https://sentry.io/for/django/).
* Use a reverse proxy. Do not expose the Healthchecks instance directly to the public
  internet, put a reverse proxy such as nginx, HAProxy, or Caddy in front of it.

  **Important:** configure the reverse proxy to set the `X-Forwarded-For` request
  header. Healthchecks trusts it to determine the client's IP address. If the proxy
  does not set the `X-Forwarded-For` header, the clients can pass their own value and
  circumvent, among other things, the IP-based rate limiting in the login form.
* Management commands that need to be run during each version upgrade.
  * `manage.py compress` – creates combined JS and CSS bundles and
     places them in the `static-collected` directory.
  * `manage.py collectstatic` – collects static files in the `static-collected`
     directory.
  * `manage.py migrate` – applies any pending database schema changes
     and data migrations.
* Processes that need to be running constantly.
  * `manage.py runserver` is intended for development only.
     **Do not use it in production**, instead consider using
     [uWSGI](https://uwsgi-docs.readthedocs.io/en/latest/) or
     [gunicorn](https://gunicorn.org/).
     An example of a minimal setup would be to install uWSGI using `pip3 install uwsgi`,
     and to run `uwsgi --http :8000 --module hc.wsgi` from the project's root directory.
  *  `manage.py sendalerts` is the process that monitors checks and sends out
     monitoring alerts. It must be always running, it must be started on reboot, and it
     must be restarted if it itself crashes. On modern linux systems, a good option is
     to [define a systemd service](https://example.com/repo/issues/273#issuecomment-520560304)
     for it.
  * `manage.py sendreports --loop` is the command that sends periodic email reports and
     the email reminders when any checks are down. If you need this functionality, make
     sure `manage.py sendreports --loop` is started on reboot and is always running,
     same as `manage.py sendalerts`.
* Static files. Healthchecks serves static files on its own, no configuration
  required. It uses the [Whitenoise library](http://whitenoise.evans.io/en/stable/index.html)
  for this.
* General
  * Make sure the database is secured well and is getting backed up regularly
  * Make sure the TLS certificates are secured well and are getting refreshed regularly
  * Have monitoring in place to be sure the Healthchecks instance itself is operational
    (is accepting pings, is sending out alerts, is not running out of resources).

