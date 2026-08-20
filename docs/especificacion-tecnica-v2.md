---
title: "Plataforma de Alto Rendimiento Deportivo"
subtitle: "Especificación Técnica v2.0 — Documento de implementación"
author: "Tomás Juárez"
date: "19 de agosto de 2026"
lang: es
toc-title: "Índice"
---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# 0. Control del documento

| Campo | Valor |
|---|---|
| Versión | 2.0 |
| Estado | Listo para ingeniería (implementable) |
| Reemplaza a | v1.0 — *Prompt Maestro: Desarrollo de App de Alto Rendimiento Deportivo* |
| Audiencia | Equipo de desarrollo, arquitectura, ciencia del deporte, agentes de código (Cursor / Copilot / Claude Code) |
| Alcance de la v2 | Modelo de datos PostgreSQL, arquitectura de microservicios, algoritmo de periodización, scoring de carga y fatiga, especificación de APIs, roadmap por fases |

**Qué cambia respecto de la v1.** La v1 definía el *qué* (objetivo de producto, variables del atleta, motor de decisión conceptual, stack sugerido, alcance MVP). La v2 define el *cómo*: esquemas, contratos, fórmulas, umbrales y secuencia de entrega. Todo lo declarado en la v1 se mantiene vigente y se incorpora aquí de forma normativa; donde la v1 era ambigua, esta versión fija una decisión y la marca como tal.

**Convenciones normativas.** Se usan las palabras clave DEBE (requisito obligatorio), DEBERÍA (recomendación fuerte, desviarse exige justificación registrada) y PUEDE (opcional).

---

# 1. Resumen ejecutivo

La plataforma genera y regula planes de entrenamiento individualizados combinando tres capas de decisión:

1. **Capa de planificación (determinista).** Un motor de periodización basado en reglas construye macrociclo, mesociclos y microciclos a partir del objetivo, el deporte, el calendario competitivo y la disponibilidad. Es reproducible y auditable: mismas entradas, mismo plan.
2. **Capa de regulación diaria (cuantitativa).** Un motor de scoring calcula carga interna y externa, ratios de carga aguda/crónica, monotonía, *strain*, estado de forma (modelo fitness–fatiga) y un índice compuesto de *readiness*. De ahí sale un ajuste diario acotado sobre el plan.
3. **Capa conversacional (LLM).** Un orquestador de IA traduce lenguaje natural del atleta o del entrenador a intenciones estructuradas y llama a las dos capas anteriores mediante herramientas tipadas. **El LLM nunca prescribe carga directamente**: propone parámetros, el motor determinista los valida contra guardarraíles y el resultado se registra en el log de decisiones.

Esta separación es la decisión arquitectónica central del producto: permite explicar cada sesión ("por qué hoy entreno esto"), auditar retroactivamente, y sustituir modelos de ML sin tocar la lógica de seguridad.

## 1.1 Advertencia de dominio y posicionamiento regulatorio

Dos puntos que el equipo debe asumir desde el día uno, porque condicionan diseño y marketing:

- **La predicción de lesiones tiene validez limitada.** La literatura reciente (Impellizzeri y cols., Bahr) muestra que ningún modelo, incluido el ACWR, alcanza precisión suficiente para predecir lesiones individuales. La plataforma DEBE presentar estas señales como **indicadores de gestión de carga y banderas de conversación**, nunca como "probabilidad de lesión". El lenguaje de UI está normado en §7.9.
- **El producto no es un dispositivo médico.** No diagnostica, no trata y no reemplaza criterio clínico. El retorno tras lesión (RTP) se modela como flujo asistido con validación humana obligatoria (§6.6). Cualquier funcionalidad que cruce esa línea exige revisión regulatoria previa (MDR en UE, FDA en EE. UU.).

---

# 2. Principios de diseño y decisiones de arquitectura

| ID | Decisión | Alternativa descartada | Motivo |
|---|---|---|---|
| ADR-01 | Motor de planificación determinista basado en reglas; ML solo como señal de entrada | Generación end-to-end con LLM | Trazabilidad, seguridad, reproducibilidad y coste |
| ADR-02 | Base de datos por servicio, con PostgreSQL como motor único | Base de datos compartida | Autonomía de despliegue sin multiplicar tecnologías |
| ADR-03 | Series temporales en PostgreSQL particionado (TimescaleDB opcional) | InfluxDB desde el inicio | Volumen del MVP no lo justifica; se evita una tecnología más |
| ADR-04 | Monolito modular en Fase 1, extracción a microservicios en Fase 2 | Microservicios desde el día uno | Coste operativo prematuro; los límites de contexto aún no están validados |
| ADR-05 | Comunicación asíncrona por eventos con patrón *outbox* | Llamadas síncronas en cadena | Resiliencia ante fallos de wearables y cargas de trabajo por lotes |
| ADR-06 | Toda decisión del motor se persiste con sus entradas y la versión de reglas | Log de aplicación sin estructura | Requisito explícito de la v1 (trazabilidad) y base para auditoría científica |
| ADR-07 | Unidad canónica de carga interna: sRPE en unidades arbitrarias (UA) | TRIMP como métrica primaria | sRPE es aplicable a fuerza y a deportes de equipo; TRIMP se calcula como métrica secundaria cuando hay FC |
| ADR-08 | Multi-tenencia por columna `organization_id` con RLS de PostgreSQL | Esquema por cliente | Simplicidad operativa hasta escala de club (Fase 4) |

---

# 3. Modelo conceptual del dominio

**Agregados principales** (raíz → entidades contenidas):

- **Athlete** → perfil, antropometría, historial médico, objetivos, disponibilidad, conexiones a wearables.
- **Assessment** → batería de tests, resultados, benchmarks normativos.
- **TrainingPlan** → macrociclo → mesociclos → microciclos → sesiones → bloques → ítems prescritos.
- **SessionExecution** → sesión realizada → series ejecutadas → feedback (RPE, dolor, comentarios).
- **DailyReadiness** → wellness, HRV, sueño, métricas derivadas de carga.
- **Decision** → cualquier acto del motor que modifica el plan, con entradas, regla aplicada y resultado.
- **Organization** → club, equipo, staff, roles y permisos (Fase 4).

**Invariantes de dominio que el código DEBE garantizar:**

1. Una sesión prescrita nunca se modifica en sitio: se versiona (`plan_session.version`) y el cambio genera una `decision`.
2. Ninguna prescripción se emite sin un `readiness_score` del día o una marca explícita de dato ausente.
3. La carga planificada de un microciclo no puede superar los guardarraíles de §6.6 sin aprobación humana registrada.
4. Todo dato biométrico está ligado a un `consent_id` vigente.

---

# 4. Modelo de datos (PostgreSQL 16)

## 4.1 Convenciones

- Claves primarias `UUID` v7 (ordenables temporalmente) generadas en aplicación; `id UUID PRIMARY KEY`.
- Marcas de tiempo `TIMESTAMPTZ`, siempre en UTC; la zona local del atleta se guarda aparte para calcular "día de entrenamiento".
- Nombres en `snake_case`, tablas en plural, enumerados como tipos `ENUM` nativos cuando el dominio es cerrado y estable, y tablas de catálogo cuando debe poder editarse sin desplegar.
- Borrado lógico (`deleted_at`) en entidades de usuario; borrado físico solo en el flujo de derecho al olvido (§9.3).
- Toda tabla con datos de atleta lleva `organization_id` para RLS.
- Auditoría mínima en todas las tablas: `created_at`, `updated_at`, `created_by`.

> El DDL de este capítulo se presenta agrupado por dominio funcional para que se lea; el orden real de creación lo fijan las migraciones (Alembic), donde los catálogos (`sports`, `positions`, `roles`) preceden a las tablas que los referencian.

```sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "btree_gist";

CREATE TYPE sex_type            AS ENUM ('male','female','other','undisclosed');
CREATE TYPE experience_level    AS ENUM ('beginner','intermediate','advanced','elite');
CREATE TYPE goal_type           AS ENUM ('strength','hypertrophy','power','speed','endurance',
                                         'body_composition','return_to_play','general_health','sport_performance');
CREATE TYPE plan_status         AS ENUM ('draft','active','paused','completed','archived');
CREATE TYPE session_status      AS ENUM ('planned','modified','completed','partial','skipped','cancelled');
CREATE TYPE mesocycle_focus     AS ENUM ('accumulation','transmutation','realization','taper','transition','rehab');
CREATE TYPE load_source         AS ENUM ('manual','wearable','gps','derived','coach');
CREATE TYPE decision_kind       AS ENUM ('plan_generation','daily_adjustment','deload','session_swap',
                                         'load_cap','rtp_gate','manual_override');
```

## 4.2 Identidad, organizaciones y permisos

```sql
CREATE TABLE organizations (
  id              UUID PRIMARY KEY,
  name            TEXT NOT NULL,
  country_code    CHAR(2),
  tier            TEXT NOT NULL DEFAULT 'individual',  -- individual | team | club | federation
  settings        JSONB NOT NULL DEFAULT '{}',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE users (
  id                  UUID PRIMARY KEY,
  organization_id     UUID NOT NULL REFERENCES organizations(id),
  email               CITEXT UNIQUE NOT NULL,
  password_hash       TEXT,                 -- NULL si solo usa OIDC
  full_name           TEXT NOT NULL,
  locale              TEXT NOT NULL DEFAULT 'es-AR',
  timezone            TEXT NOT NULL DEFAULT 'America/Argentina/Buenos_Aires',
  mfa_enabled         BOOLEAN NOT NULL DEFAULT false,
  last_login_at       TIMESTAMPTZ,
  deleted_at          TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE roles (           -- athlete, coach, s&c_coach, physio, analyst, org_admin, support
  id    SMALLINT PRIMARY KEY,
  code  TEXT UNIQUE NOT NULL,
  name  TEXT NOT NULL
);

CREATE TABLE user_roles (
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id          SMALLINT NOT NULL REFERENCES roles(id),
  organization_id  UUID NOT NULL REFERENCES organizations(id),
  team_id          UUID,                    -- NULL = alcance de organización
  granted_by       UUID REFERENCES users(id),
  granted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  id               UUID PRIMARY KEY
);
-- Unicidad con team_id opcional: índice sobre expresión (PostgreSQL no admite
-- COALESCE en una restricción PRIMARY KEY / UNIQUE, sí en un índice único).
CREATE UNIQUE INDEX user_roles_scope_uq ON user_roles
  (user_id, role_id, organization_id,
   COALESCE(team_id, '00000000-0000-0000-0000-000000000000'::uuid));

CREATE TABLE teams (
  id               UUID PRIMARY KEY,
  organization_id  UUID NOT NULL REFERENCES organizations(id),
  sport_id         SMALLINT NOT NULL,
  name             TEXT NOT NULL,
  season_start     DATE,
  season_end       DATE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

## 4.3 Atleta: perfil, antropometría, disponibilidad

```sql
CREATE TABLE athletes (
  id                    UUID PRIMARY KEY,
  user_id               UUID UNIQUE REFERENCES users(id),
  organization_id       UUID NOT NULL REFERENCES organizations(id),
  birth_date            DATE NOT NULL,
  sex                   sex_type NOT NULL,
  primary_sport_id      SMALLINT NOT NULL REFERENCES sports(id),
  position_id           SMALLINT REFERENCES positions(id),
  experience            experience_level NOT NULL,
  training_age_years    NUMERIC(4,1),            -- años de entrenamiento estructurado
  dominant_side         TEXT,                    -- left | right | ambidextrous
  onboarding_completed  BOOLEAN NOT NULL DEFAULT false,
  status                TEXT NOT NULL DEFAULT 'active',  -- active | injured | resting | inactive
  deleted_at            TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE athlete_team_memberships (
  athlete_id  UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  team_id     UUID NOT NULL REFERENCES teams(id)    ON DELETE CASCADE,
  position_id SMALLINT REFERENCES positions(id),
  period      DATERANGE NOT NULL,
  PRIMARY KEY (athlete_id, team_id, period),
  EXCLUDE USING gist (athlete_id WITH =, team_id WITH =, period WITH &&)
);

CREATE TABLE anthropometrics (            -- serie temporal, no sobrescribir
  id              UUID PRIMARY KEY,
  athlete_id      UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  measured_on     DATE NOT NULL,
  height_cm       NUMERIC(5,1),
  weight_kg       NUMERIC(5,2),
  body_fat_pct    NUMERIC(4,1),
  lean_mass_kg    NUMERIC(5,2),
  method          TEXT,                   -- bioimpedance | dexa | skinfolds | self_report
  skinfolds       JSONB,                  -- {"triceps": 8.2, "subscapular": 10.1, ...}
  girths          JSONB,
  source          load_source NOT NULL DEFAULT 'manual',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (athlete_id, measured_on, method)
);

CREATE TABLE athlete_goals (
  id             UUID PRIMARY KEY,
  athlete_id     UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  goal           goal_type NOT NULL,
  priority       SMALLINT NOT NULL DEFAULT 1,      -- 1 = principal
  target_metric  TEXT,                             -- 'back_squat_1rm' | 'vo2max' | '5k_time'
  target_value   NUMERIC(10,3),
  target_unit    TEXT,
  target_date    DATE,
  achieved_at    TIMESTAMPTZ,
  notes          TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE athlete_availability (        -- disponibilidad semanal recurrente
  id                 UUID PRIMARY KEY,
  athlete_id         UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  weekday            SMALLINT NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  start_time         TIME NOT NULL,
  end_time           TIME NOT NULL,
  equipment_context  TEXT NOT NULL DEFAULT 'full_gym',  -- full_gym | home | field | pool | minimal
  effective_from     DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_to       DATE,
  CHECK (end_time > start_time)
);

CREATE TABLE calendar_events (             -- competencias, viajes, bloqueos puntuales
  id            UUID PRIMARY KEY,
  athlete_id    UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  team_id       UUID REFERENCES teams(id),
  kind          TEXT NOT NULL,             -- competition | travel | unavailable | camp | test
  importance    SMALLINT DEFAULT 1,        -- 1..5, 5 = objetivo principal de temporada
  title         TEXT NOT NULL,
  starts_at     TIMESTAMPTZ NOT NULL,
  ends_at       TIMESTAMPTZ NOT NULL,
  metadata      JSONB NOT NULL DEFAULT '{}',
  CHECK (ends_at > starts_at)
);
```

## 4.4 Catálogos deportivos y biblioteca de ejercicios

```sql
CREATE TABLE sports (
  id           SMALLINT PRIMARY KEY,
  code         TEXT UNIQUE NOT NULL,     -- rugby | football | field_hockey | running | strength
  name         TEXT NOT NULL,
  category     TEXT NOT NULL,            -- team_invasion | endurance | strength | racquet
  demands      JSONB NOT NULL DEFAULT '{}' -- perfil bioenergético y mecánico por defecto
);

CREATE TABLE positions (
  id           SMALLINT PRIMARY KEY,
  sport_id     SMALLINT NOT NULL REFERENCES sports(id),
  code         TEXT NOT NULL,
  name         TEXT NOT NULL,
  demand_profile JSONB NOT NULL DEFAULT '{}', -- {"hsr_m_per_match": 650, "accels_per_match": 42, ...}
  UNIQUE (sport_id, code)
);

CREATE TABLE exercises (
  id                 UUID PRIMARY KEY,
  organization_id    UUID REFERENCES organizations(id),  -- NULL = catálogo global
  code               TEXT NOT NULL,
  name               TEXT NOT NULL,
  category           TEXT NOT NULL,       -- squat | hinge | push | pull | carry | plyo | sprint | conditioning | mobility
  pattern            TEXT NOT NULL,
  primary_muscles    TEXT[] NOT NULL DEFAULT '{}',
  secondary_muscles  TEXT[] NOT NULL DEFAULT '{}',
  equipment          TEXT[] NOT NULL DEFAULT '{}',
  unilateral         BOOLEAN NOT NULL DEFAULT false,
  technical_demand   SMALLINT NOT NULL DEFAULT 3 CHECK (technical_demand BETWEEN 1 AND 5),
  neural_cost        SMALLINT NOT NULL DEFAULT 3 CHECK (neural_cost BETWEEN 1 AND 5),
  eccentric_load     SMALLINT NOT NULL DEFAULT 3 CHECK (eccentric_load BETWEEN 1 AND 5),
  contraindications  TEXT[] NOT NULL DEFAULT '{}',   -- body_region afectada
  progressions       UUID[] NOT NULL DEFAULT '{}',
  regressions        UUID[] NOT NULL DEFAULT '{}',
  media              JSONB NOT NULL DEFAULT '{}',
  is_active          BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX exercises_code_uq ON exercises
  (COALESCE(organization_id, '00000000-0000-0000-0000-000000000000'::uuid), code);

CREATE TABLE exercise_substitutions (      -- equivalencias por equipamiento o restricción
  exercise_id      UUID NOT NULL REFERENCES exercises(id) ON DELETE CASCADE,
  substitute_id    UUID NOT NULL REFERENCES exercises(id) ON DELETE CASCADE,
  similarity       NUMERIC(3,2) NOT NULL CHECK (similarity BETWEEN 0 AND 1),
  reason           TEXT NOT NULL,          -- equipment | injury | skill | space
  PRIMARY KEY (exercise_id, substitute_id, reason)
);
```

## 4.5 Evaluación y tests

```sql
CREATE TABLE test_definitions (
  id             SMALLINT PRIMARY KEY,
  code           TEXT UNIQUE NOT NULL,   -- cmj | sprint_10m | yoyo_ir1 | back_squat_1rm | fms | nordic_break
  name           TEXT NOT NULL,          -- Salto contramovimiento, Sprint 10 m, ...
  quality        TEXT NOT NULL,          -- power | speed | endurance | strength | mobility | asymmetry
  unit           TEXT NOT NULL,
  higher_is_better BOOLEAN NOT NULL DEFAULT true,
  protocol       JSONB NOT NULL DEFAULT '{}',
  min_rest_hours SMALLINT NOT NULL DEFAULT 24
);

CREATE TABLE test_results (
  id             UUID PRIMARY KEY,
  athlete_id     UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  test_id        SMALLINT NOT NULL REFERENCES test_definitions(id),
  performed_at   TIMESTAMPTZ NOT NULL,
  value          NUMERIC(10,3) NOT NULL,
  side           TEXT,                    -- left | right | bilateral
  is_estimated   BOOLEAN NOT NULL DEFAULT false,   -- p. ej. 1RM estimado desde submáximo
  estimation_formula TEXT,                          -- epley | brzycki | lombardi
  conditions     JSONB NOT NULL DEFAULT '{}',
  percentile     NUMERIC(4,1),            -- vs. norma de deporte/posición/edad/sexo
  source         load_source NOT NULL DEFAULT 'manual',
  created_by     UUID REFERENCES users(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON test_results (athlete_id, test_id, performed_at DESC);

CREATE TABLE normative_benchmarks (
  test_id     SMALLINT NOT NULL REFERENCES test_definitions(id),
  sport_id    SMALLINT REFERENCES sports(id),
  position_id SMALLINT REFERENCES positions(id),
  sex         sex_type NOT NULL,
  age_min     SMALLINT NOT NULL,
  age_max     SMALLINT NOT NULL,
  level       experience_level NOT NULL,
  p10 NUMERIC(10,3), p25 NUMERIC(10,3), p50 NUMERIC(10,3), p75 NUMERIC(10,3), p90 NUMERIC(10,3),
  sample_size INTEGER,
  reference   TEXT,                       -- cita bibliográfica de la norma
  PRIMARY KEY (test_id, sport_id, position_id, sex, age_min, age_max, level)
);
```

## 4.6 Planificación: macrociclo → ítem prescrito

```sql
CREATE TABLE training_plans (              -- macrociclo
  id                 UUID PRIMARY KEY,
  athlete_id         UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  organization_id    UUID NOT NULL REFERENCES organizations(id),
  name               TEXT NOT NULL,
  primary_goal       goal_type NOT NULL,
  starts_on          DATE NOT NULL,
  ends_on            DATE NOT NULL,
  status             plan_status NOT NULL DEFAULT 'draft',
  target_event_id    UUID REFERENCES calendar_events(id),
  generator_version  TEXT NOT NULL,        -- versión del motor que lo creó
  ruleset_version    TEXT NOT NULL,
  generation_inputs  JSONB NOT NULL,       -- snapshot inmutable de las entradas
  approved_by        UUID REFERENCES users(id),
  approved_at        TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ends_on > starts_on)
);

CREATE TABLE mesocycles (
  id                 UUID PRIMARY KEY,
  plan_id            UUID NOT NULL REFERENCES training_plans(id) ON DELETE CASCADE,
  ordinal            SMALLINT NOT NULL,
  name               TEXT NOT NULL,
  focus              mesocycle_focus NOT NULL,
  starts_on          DATE NOT NULL,
  ends_on            DATE NOT NULL,
  target_qualities   TEXT[] NOT NULL DEFAULT '{}',
  planned_load_au    INTEGER,             -- carga interna objetivo del bloque
  deload_week        SMALLINT,            -- ordinal del microciclo de descarga
  UNIQUE (plan_id, ordinal)
);

CREATE TABLE microcycles (
  id                 UUID PRIMARY KEY,
  mesocycle_id       UUID NOT NULL REFERENCES mesocycles(id) ON DELETE CASCADE,
  ordinal            SMALLINT NOT NULL,
  starts_on          DATE NOT NULL,
  ends_on            DATE NOT NULL,
  pattern            TEXT NOT NULL,       -- loading | unloading | competition | recovery
  planned_load_au    INTEGER NOT NULL,
  planned_monotony   NUMERIC(4,2),
  UNIQUE (mesocycle_id, ordinal)
);

CREATE TABLE plan_sessions (
  id                 UUID PRIMARY KEY,
  microcycle_id      UUID NOT NULL REFERENCES microcycles(id) ON DELETE CASCADE,
  athlete_id         UUID NOT NULL REFERENCES athletes(id),
  scheduled_date     DATE NOT NULL,
  scheduled_time     TIME,
  version            SMALLINT NOT NULL DEFAULT 1,
  supersedes_id      UUID REFERENCES plan_sessions(id),
  session_type       TEXT NOT NULL,       -- strength | speed | conditioning | technical | recovery | test | match
  primary_quality    TEXT NOT NULL,
  planned_duration_min SMALLINT NOT NULL,
  planned_load_au    INTEGER NOT NULL,    -- duración × RPE objetivo
  target_rpe         NUMERIC(3,1),
  equipment_context  TEXT NOT NULL DEFAULT 'full_gym',
  status             session_status NOT NULL DEFAULT 'planned',
  notes              TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (athlete_id, scheduled_date, version, session_type)
);
CREATE INDEX ON plan_sessions (athlete_id, scheduled_date);

CREATE TABLE session_blocks (
  id             UUID PRIMARY KEY,
  session_id     UUID NOT NULL REFERENCES plan_sessions(id) ON DELETE CASCADE,
  ordinal        SMALLINT NOT NULL,
  block_type     TEXT NOT NULL,           -- warmup | main | accessory | conditioning | cooldown | prehab
  structure      TEXT NOT NULL DEFAULT 'straight',  -- straight | superset | circuit | emom | interval
  rest_seconds   SMALLINT,
  UNIQUE (session_id, ordinal)
);

CREATE TABLE prescribed_items (
  id                 UUID PRIMARY KEY,
  block_id           UUID NOT NULL REFERENCES session_blocks(id) ON DELETE CASCADE,
  ordinal            SMALLINT NOT NULL,
  exercise_id        UUID NOT NULL REFERENCES exercises(id),
  sets               SMALLINT NOT NULL,
  reps_min           SMALLINT,
  reps_max           SMALLINT,
  intensity_type     TEXT NOT NULL,       -- pct_1rm | rpe | rir | velocity | pct_hrmax | pace | absolute
  intensity_value    NUMERIC(6,2),
  intensity_upper    NUMERIC(6,2),        -- para rangos
  tempo              TEXT,                -- '30X1'
  rest_seconds       SMALLINT,
  duration_seconds   SMALLINT,
  distance_m         NUMERIC(8,1),
  load_kg            NUMERIC(6,2),        -- resuelto desde %1RM al momento de prescribir
  velocity_loss_pct  NUMERIC(4,1),        -- umbral de corte para VBT
  autoregulation     JSONB NOT NULL DEFAULT '{}', -- {"rule":"rir_stop","rir_floor":2}
  notes              TEXT,
  UNIQUE (block_id, ordinal)
);
```

## 4.7 Ejecución y feedback

```sql
CREATE TABLE session_executions (
  id                  UUID PRIMARY KEY,
  plan_session_id     UUID REFERENCES plan_sessions(id),   -- NULL = sesión no planificada
  athlete_id          UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  started_at          TIMESTAMPTZ NOT NULL,
  ended_at            TIMESTAMPTZ,
  duration_min        SMALLINT,
  session_rpe         NUMERIC(3,1) CHECK (session_rpe BETWEEN 0 AND 10),
  rpe_collected_at    TIMESTAMPTZ,        -- válido a partir de 30 min post-sesión
  internal_load_au    INTEGER,            -- duration_min × session_rpe
  completion_pct      NUMERIC(4,1),
  pain_reported       BOOLEAN NOT NULL DEFAULT false,
  pain_details        JSONB,              -- {"region":"hamstring_left","nrs":4,"onset":"during"}
  environment         JSONB,              -- {"temp_c":31,"altitude_m":900,"surface":"artificial"}
  athlete_comment     TEXT,
  status              session_status NOT NULL DEFAULT 'completed',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON session_executions (athlete_id, started_at DESC);

CREATE TABLE set_logs (
  id                UUID PRIMARY KEY,
  execution_id      UUID NOT NULL REFERENCES session_executions(id) ON DELETE CASCADE,
  prescribed_item_id UUID REFERENCES prescribed_items(id),
  exercise_id       UUID NOT NULL REFERENCES exercises(id),
  set_number        SMALLINT NOT NULL,
  reps              SMALLINT,
  load_kg           NUMERIC(6,2),
  rir               NUMERIC(3,1),
  rpe               NUMERIC(3,1),
  mean_velocity_ms  NUMERIC(4,2),
  peak_velocity_ms  NUMERIC(4,2),
  distance_m        NUMERIC(8,1),
  duration_seconds  SMALLINT,
  volume_load_kg    NUMERIC(10,2) GENERATED ALWAYS AS (COALESCE(reps,0) * COALESCE(load_kg,0)) STORED,
  was_substituted   BOOLEAN NOT NULL DEFAULT false,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON set_logs (execution_id, exercise_id);
```

## 4.8 Wellness, sueño y variabilidad cardíaca

```sql
CREATE TABLE wellness_entries (            -- cuestionario Hooper adaptado, 1 por día
  athlete_id       UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  entry_date       DATE NOT NULL,
  sleep_quality    SMALLINT CHECK (sleep_quality BETWEEN 1 AND 5),
  sleep_hours      NUMERIC(3,1),
  fatigue          SMALLINT CHECK (fatigue BETWEEN 1 AND 5),
  muscle_soreness  SMALLINT CHECK (muscle_soreness BETWEEN 1 AND 5),
  stress           SMALLINT CHECK (stress BETWEEN 1 AND 5),
  mood             SMALLINT CHECK (mood BETWEEN 1 AND 5),
  soreness_map     JSONB NOT NULL DEFAULT '{}',  -- {"quad_left":3,"lower_back":2}
  motivation       SMALLINT,
  notes            TEXT,
  source           load_source NOT NULL DEFAULT 'manual',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (athlete_id, entry_date)
);

CREATE TABLE hrv_readings (
  id             UUID PRIMARY KEY,
  athlete_id     UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  measured_at    TIMESTAMPTZ NOT NULL,
  measurement_date DATE NOT NULL,
  rmssd_ms       NUMERIC(6,2),
  ln_rmssd       NUMERIC(5,3),
  sdnn_ms        NUMERIC(6,2),
  resting_hr_bpm SMALLINT,
  protocol       TEXT NOT NULL DEFAULT 'supine_morning',  -- supine_morning | sleep_avg | seated
  duration_s     SMALLINT,
  device_id      UUID REFERENCES wearable_connections(id),
  quality_flag   TEXT,                    -- ok | artifact | short | manual_review
  source         load_source NOT NULL DEFAULT 'wearable',
  UNIQUE (athlete_id, measurement_date, protocol)
);

CREATE TABLE sleep_records (
  id                 UUID PRIMARY KEY,
  athlete_id         UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  sleep_date         DATE NOT NULL,       -- noche que termina en esta fecha
  bedtime            TIMESTAMPTZ,
  wake_time          TIMESTAMPTZ,
  total_sleep_min    SMALLINT,
  deep_min           SMALLINT,
  rem_min            SMALLINT,
  light_min          SMALLINT,
  awake_min          SMALLINT,
  efficiency_pct     NUMERIC(4,1),
  respiratory_rate   NUMERIC(4,1),
  source             load_source NOT NULL DEFAULT 'wearable',
  device_id          UUID REFERENCES wearable_connections(id),
  UNIQUE (athlete_id, sleep_date, source)
);
```

## 4.9 Carga externa e interna, métricas derivadas

```sql
CREATE TABLE external_load_records (       -- GPS/LPS por sesión o partido; particionada por mes
  id                   UUID NOT NULL,
  athlete_id           UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  execution_id         UUID REFERENCES session_executions(id),
  recorded_on          DATE NOT NULL,
  total_distance_m     NUMERIC(9,1),
  hsr_distance_m       NUMERIC(9,1),      -- > 19.8 km/h (parametrizable por deporte)
  sprint_distance_m    NUMERIC(9,1),      -- > 25.2 km/h
  max_speed_ms         NUMERIC(4,2),
  accelerations_n      SMALLINT,          -- > 3 m/s²
  decelerations_n      SMALLINT,          -- < -3 m/s²
  player_load_au       NUMERIC(8,2),
  metabolic_power_avg  NUMERIC(6,2),
  impacts_n            SMALLINT,
  device_vendor        TEXT,
  raw_payload_ref      TEXT,              -- puntero a objeto en almacenamiento frío
  PRIMARY KEY (id, recorded_on)
) PARTITION BY RANGE (recorded_on);

CREATE TABLE daily_load_metrics (          -- una fila por atleta y día; calculada por el motor
  athlete_id            UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  metric_date           DATE NOT NULL,
  internal_load_au      INTEGER NOT NULL DEFAULT 0,
  external_load_au      NUMERIC(10,2),
  trimp                 NUMERIC(8,2),
  volume_load_kg        NUMERIC(10,2),
  acute_load_7d         NUMERIC(10,2),
  chronic_load_28d      NUMERIC(10,2),
  acwr_ra               NUMERIC(5,3),     -- rolling average
  acwr_ewma             NUMERIC(5,3),     -- exponentially weighted
  weekly_load_au        NUMERIC(10,2),
  week_over_week_pct    NUMERIC(6,2),
  monotony              NUMERIC(5,2),
  strain                NUMERIC(12,2),
  fitness_ctl           NUMERIC(8,2),     -- modelo fitness-fatiga, τ = 42 d
  fatigue_atl           NUMERIC(8,2),     -- τ = 7 d
  form_tsb              NUMERIC(8,2),     -- fitness − fatiga
  hrv_baseline_ln       NUMERIC(5,3),
  hrv_swc_lower         NUMERIC(5,3),
  hrv_swc_upper         NUMERIC(5,3),
  hrv_status            TEXT,             -- above | within | below | insufficient_data
  readiness_score       NUMERIC(5,2),     -- 0..100
  readiness_band        TEXT,             -- green | amber | red
  risk_flags            TEXT[] NOT NULL DEFAULT '{}',
  data_completeness_pct NUMERIC(4,1),
  computed_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  engine_version        TEXT NOT NULL,
  PRIMARY KEY (athlete_id, metric_date)
);
```

## 4.10 Lesiones, restricciones y retorno al juego

```sql
CREATE TABLE injuries (
  id                 UUID PRIMARY KEY,
  athlete_id         UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  body_region        TEXT NOT NULL,       -- codificado según OSICS-10 / OSIICS
  side               TEXT,
  tissue_type        TEXT,                -- muscle | tendon | ligament | bone | joint | other
  osiics_code        TEXT,
  mechanism          TEXT,                -- contact | non_contact | overuse | recurrence
  severity_days      SMALLINT,            -- días de baja estimados/reales
  occurred_on        DATE NOT NULL,
  diagnosed_on       DATE,
  cleared_on         DATE,
  is_recurrence_of   UUID REFERENCES injuries(id),
  diagnosis_source   TEXT,                -- self_report | physio | physician | imaging
  notes              TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON injuries (athlete_id, occurred_on DESC);

CREATE TABLE training_restrictions (
  id             UUID PRIMARY KEY,
  athlete_id     UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  injury_id      UUID REFERENCES injuries(id),
  restriction    TEXT NOT NULL,           -- no_axial_load | no_sprint | no_eccentric_hamstring | max_rpe_6
  body_region    TEXT,
  parameters     JSONB NOT NULL DEFAULT '{}',
  valid_from     DATE NOT NULL,
  valid_to       DATE,
  issued_by      UUID REFERENCES users(id),
  requires_clearance BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE rtp_stages (                  -- protocolo de retorno progresivo
  id             UUID PRIMARY KEY,
  injury_id      UUID NOT NULL REFERENCES injuries(id) ON DELETE CASCADE,
  stage_number   SMALLINT NOT NULL,
  name           TEXT NOT NULL,
  entry_criteria JSONB NOT NULL,          -- {"nrs_max":2,"lsi_pct_min":90,"pain_free_days":3}
  exit_criteria  JSONB NOT NULL,
  started_on     DATE,
  cleared_on     DATE,
  cleared_by     UUID REFERENCES users(id),
  UNIQUE (injury_id, stage_number)
);
```

## 4.11 Trazabilidad de decisiones

Requisito explícito de la v1. Toda modificación del plan producida por el sistema DEBE dejar registro reproducible.

```sql
CREATE TABLE decisions (
  id                 UUID PRIMARY KEY,
  athlete_id         UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  decision_date      DATE NOT NULL,
  kind               decision_kind NOT NULL,
  subject_type       TEXT NOT NULL,       -- plan | session | prescribed_item
  subject_id         UUID NOT NULL,
  engine_version     TEXT NOT NULL,
  ruleset_version    TEXT NOT NULL,
  model_version      TEXT,                -- si intervino un modelo de ML
  llm_model          TEXT,                -- si intervino un LLM
  inputs             JSONB NOT NULL,      -- snapshot completo de las entradas usadas
  rules_fired        JSONB NOT NULL,      -- [{"rule":"ACWR_HIGH","threshold":1.5,"value":1.62}]
  action             JSONB NOT NULL,      -- {"type":"reduce_volume","factor":0.7}
  rationale_es       TEXT NOT NULL,       -- explicación en lenguaje natural para el atleta
  confidence         NUMERIC(3,2),
  requires_review    BOOLEAN NOT NULL DEFAULT false,
  reviewed_by        UUID REFERENCES users(id),
  reviewed_at        TIMESTAMPTZ,
  review_outcome     TEXT,                -- accepted | overridden | rejected
  override_reason    TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON decisions (athlete_id, decision_date DESC);
CREATE INDEX ON decisions USING gin (inputs jsonb_path_ops);

CREATE TABLE rulesets (                    -- versiona el conjunto de reglas deportivas
  version      TEXT PRIMARY KEY,
  definition   JSONB NOT NULL,
  published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_by UUID REFERENCES users(id),
  changelog    TEXT NOT NULL,
  is_active    BOOLEAN NOT NULL DEFAULT false
);
```

## 4.12 Integraciones y wearables

```sql
CREATE TABLE wearable_connections (
  id                 UUID PRIMARY KEY,
  athlete_id         UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  provider           TEXT NOT NULL,       -- garmin | polar | whoop | apple_health | fitbit | oura | catapult
  external_user_id   TEXT,
  access_token_enc   BYTEA,               -- cifrado con clave gestionada en KMS
  refresh_token_enc  BYTEA,
  scopes             TEXT[] NOT NULL DEFAULT '{}',
  token_expires_at   TIMESTAMPTZ,
  status             TEXT NOT NULL DEFAULT 'active',  -- active | expired | revoked | error
  last_sync_at       TIMESTAMPTZ,
  last_error         TEXT,
  connected_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (athlete_id, provider)
);

CREATE TABLE sync_jobs (
  id             UUID PRIMARY KEY,
  connection_id  UUID NOT NULL REFERENCES wearable_connections(id) ON DELETE CASCADE,
  window_start   TIMESTAMPTZ NOT NULL,
  window_end     TIMESTAMPTZ NOT NULL,
  status         TEXT NOT NULL DEFAULT 'pending',   -- pending | running | success | failed | partial
  attempts       SMALLINT NOT NULL DEFAULT 0,
  records_ingested INTEGER,
  error          TEXT,
  started_at     TIMESTAMPTZ,
  finished_at    TIMESTAMPTZ
);

CREATE TABLE raw_ingest_payloads (         -- fuente de verdad cruda, reprocesable
  id             UUID PRIMARY KEY,
  connection_id  UUID NOT NULL REFERENCES wearable_connections(id),
  provider       TEXT NOT NULL,
  payload_type   TEXT NOT NULL,
  received_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  checksum       TEXT NOT NULL,
  storage_ref    TEXT NOT NULL,           -- s3://bucket/key
  processed_at   TIMESTAMPTZ,
  UNIQUE (connection_id, checksum)
);
```

## 4.13 IA conversacional

```sql
CREATE TABLE ai_conversations (
  id             UUID PRIMARY KEY,
  athlete_id     UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  context_type   TEXT NOT NULL DEFAULT 'general',  -- general | session | plan | nutrition | injury
  context_ref    UUID
);

CREATE TABLE ai_messages (
  id                UUID PRIMARY KEY,
  conversation_id   UUID NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
  role              TEXT NOT NULL,        -- user | assistant | tool
  content           TEXT,
  tool_calls        JSONB,
  tool_results      JSONB,
  model             TEXT,
  prompt_tokens     INTEGER,
  completion_tokens INTEGER,
  latency_ms        INTEGER,
  safety_flags      TEXT[] NOT NULL DEFAULT '{}',
  decision_id       UUID REFERENCES decisions(id),   -- si derivó en cambio de plan
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

## 4.14 Consentimiento y auditoría

```sql
CREATE TABLE consents (
  id             UUID PRIMARY KEY,
  user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose        TEXT NOT NULL,          -- health_data_processing | wearable_sync | club_sharing | research | marketing
  granted        BOOLEAN NOT NULL,
  policy_version TEXT NOT NULL,
  granted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at     TIMESTAMPTZ,
  ip_address     INET,
  UNIQUE (user_id, purpose, policy_version)
);

CREATE TABLE audit_log (
  id           BIGINT GENERATED ALWAYS AS IDENTITY,
  occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor_id     UUID,
  actor_role   TEXT,
  action       TEXT NOT NULL,           -- read | create | update | delete | export | login
  resource     TEXT NOT NULL,
  resource_id  UUID,
  athlete_id   UUID,                    -- sujeto de los datos, para responder a solicitudes RGPD
  ip_address   INET,
  user_agent   TEXT,
  metadata     JSONB NOT NULL DEFAULT '{}',
  PRIMARY KEY (id, occurred_at)   -- la clave debe incluir la columna de particionado
) PARTITION BY RANGE (occurred_at);
```

## 4.15 Índices, particionado, retención y seguridad a nivel de fila

- **Particionado mensual** en `external_load_records`, `audit_log` y `ai_messages`; creación automática de particiones con `pg_partman`.
- **Índices críticos:** `(athlete_id, metric_date DESC)` en `daily_load_metrics`; `(athlete_id, scheduled_date)` en `plan_sessions`; GIN sobre `decisions.inputs` para auditoría; `(athlete_id, measurement_date)` en `hrv_readings`.
- **Vistas materializadas:** `mv_athlete_weekly_summary` (carga semanal, adherencia, ACWR de cierre) refrescada cada noche; `mv_team_load_board` para la vista de club (Fase 4).
- **RLS obligatorio** en toda tabla con `athlete_id` u `organization_id`:

```sql
ALTER TABLE daily_load_metrics ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON daily_load_metrics
  USING (athlete_id IN (SELECT athlete_id FROM accessible_athletes(current_setting('app.user_id')::uuid)));
```

- **Retención:** payloads crudos 24 meses en almacenamiento frío; `audit_log` 7 años; datos de atleta hasta 24 meses tras la baja, luego anonimización irreversible (se conservan agregados sin identificador).

---

# 5. Arquitectura de microservicios

## 5.1 Estrategia de evolución

La Fase 1 se construye como **monolito modular** en FastAPI: un despliegue, módulos con fronteras estrictas (cada módulo expone una interfaz de aplicación y no importa modelos de otro), esquemas de base de datos separados. En Fase 2 se extraen los servicios cuyo perfil de carga o cadencia de despliegue lo justifica —integraciones, analítica de carga y orquestador de IA—, sin reescribir la lógica de dominio. Esta secuencia evita pagar el coste operativo de doce servicios antes de tener tráfico real, manteniendo la separación que hace barata la extracción.

## 5.2 Catálogo de servicios

| Servicio | Responsabilidad | Datos propios | Interfaz |
|---|---|---|---|
| `api-gateway` | Enrutado, autenticación, límite de tasa, agregación BFF para móvil | — | REST/HTTPS, WebSocket |
| `identity-service` | Usuarios, roles, OIDC, MFA, consentimientos | `users`, `roles`, `consents` | REST + JWKS |
| `athlete-service` | Perfil, antropometría, objetivos, disponibilidad, calendario | §4.3 | REST, eventos |
| `assessment-service` | Tests, resultados, percentiles normativos, estimación de 1RM | §4.5 | REST, eventos |
| `planning-service` | Motor de periodización, plan, sesiones, prescripciones | §4.6 | REST, eventos, gRPC interno |
| `execution-service` | Registro de sesiones, series, RPE, feedback y adherencia | §4.7 | REST, eventos |
| `load-analytics-service` | Carga interna/externa, ACWR, monotonía, fitness–fatiga, readiness | §4.8, §4.9 | REST de lectura, jobs nocturnos |
| `risk-service` | Banderas de gestión de carga, señales de riesgo, RTP | §4.10 | REST, eventos |
| `integration-service` | OAuth con wearables, sincronización, normalización, deduplicación | §4.12 | REST, webhooks entrantes, workers |
| `ai-orchestrator` | LLM, herramientas tipadas, RAG sobre plan del atleta, guardarraíles | §4.13 | REST, SSE (streaming) |
| `notification-service` | Push, email, recordatorios, resúmenes semanales | plantillas, envíos | consumidor de eventos |
| `reporting-service` | Informes de atleta y equipo, exportaciones CSV/PDF | vistas de lectura | REST, jobs |
| `admin-service` | Gestión de reglas (`rulesets`), catálogos, back-office | §4.11 | REST |

## 5.3 Comunicación

**Síncrona (REST/gRPC)** solo para lecturas y comandos que requieren respuesta inmediata en pantalla. Prohibidas las cadenas síncronas de más de dos saltos.

**Asíncrona (bus de eventos: NATS JetStream en Fase 2; Kafka a partir de Fase 4)** para todo lo demás. Eventos con esquema versionado (Avro o JSON Schema) publicados vía patrón *outbox* transaccional.

| Evento | Publica | Consumen | Carga útil (extracto) |
|---|---|---|---|
| `athlete.profile.updated` | athlete-service | planning, risk | `athlete_id`, campos modificados |
| `assessment.completed` | assessment-service | planning, reporting | `test_results[]`, `percentiles` |
| `session.executed` | execution-service | load-analytics, risk, notification | `execution_id`, `internal_load_au`, `rpe` |
| `wellness.submitted` | athlete-service | load-analytics | `entry_date`, puntuaciones |
| `wearable.data.ingested` | integration-service | load-analytics | `athlete_id`, `types[]`, `window` |
| `metrics.daily.computed` | load-analytics | planning, risk, notification | `readiness_score`, `acwr`, `flags[]` |
| `plan.adjusted` | planning-service | notification, reporting | `decision_id`, `changes[]` |
| `risk.flag.raised` | risk-service | notification, planning | `flag`, `severity`, `evidence` |
| `injury.reported` | athlete-service | planning, risk, notification | `injury_id`, `body_region`, `severity_days` |

## 5.4 Patrones obligatorios

- **Outbox transaccional:** el evento se escribe en la misma transacción que el cambio de estado; un *relay* lo publica. Nunca `commit` + `publish` como pasos separados.
- **Idempotencia:** todo consumidor guarda `(event_id, consumer)` procesados; todo `POST` mutante acepta cabecera `Idempotency-Key`.
- **Saga de generación de plan:** `planning` solicita métricas → si `load-analytics` no responde en 2 s, genera con la última instantánea disponible y marca `data_completeness_pct`; nunca bloquea al usuario.
- **CQRS ligero:** las lecturas de dashboards van contra vistas materializadas o réplica de lectura, nunca contra las tablas transaccionales.
- **Compensación:** un plan generado sobre datos incompletos se marca `requires_review = true` y se regenera automáticamente cuando llegan los datos faltantes, produciendo una nueva `decision` de tipo `daily_adjustment`.

## 5.5 Infraestructura

```
Cliente móvil (React Native + Expo)  ─┐
Cliente web (Next.js)                ─┤→ CDN → API Gateway (Kong/Traefik) → servicios (Kubernetes)
Panel de club (Next.js)              ─┘                                          │
                                                                                  ├→ PostgreSQL 16 (primario + réplica)
                                                                                  ├→ Redis (caché, colas cortas, rate limit)
                                                                                  ├→ NATS JetStream / Kafka
                                                                                  ├→ S3/MinIO (payloads crudos, media)
                                                                                  └→ ClickHouse (analítica, desde Fase 3)
```

- **Contenedores:** Docker multi-stage; imágenes distroless.
- **Orquestación:** Kubernetes (EKS/GKE) con HPA por latencia p95 y profundidad de cola.
- **CI/CD:** GitHub Actions → pruebas → escaneo SAST/dependencias → despliegue *canary* → promoción automática si el error rate se mantiene bajo el umbral 20 minutos.
- **Observabilidad:** OpenTelemetry (trazas, métricas, logs) → Grafana/Tempo/Loki; `decision_id` y `athlete_id` propagados como atributos de traza para reconstruir cualquier recomendación extremo a extremo.
- **Entornos:** `dev`, `staging` (con datos sintéticos), `prod`. Ningún dato real de atleta fuera de producción.

---

# 6. Algoritmo de periodización

## 6.1 Entradas

```
G  objetivo primario y secundarios, con fecha objetivo
S  deporte, posición y perfil de demanda
E  estado actual: tests, percentiles, 1RM, umbrales, historial de carga
H  historial médico: lesiones, recurrencias, restricciones vigentes
C  calendario: competencias (con importancia 1-5), viajes, bloqueos
D  disponibilidad: días, ventanas horarias, equipamiento por ventana
P  preferencias: ejercicios preferidos/vetados, deportes complementarios
R  guardarraíles del ruleset activo
```

## 6.2 Pipeline de generación (8 etapas)

**Etapa 1 — Normalización y validación.** Se completa el perfil, se detectan datos faltantes críticos (sin 1RM ni test de fuerza no se prescribe %1RM: se usa RPE/RIR) y se calcula `data_completeness_pct`.

**Etapa 2 — Estructura del macrociclo.** Se ubican los picos de rendimiento sobre los eventos de importancia ≥ 4 y se divide el horizonte en mesociclos según la distancia al pico:

- \> 16 semanas al pico: secuencia `accumulation → transmutation → realization` repetida (periodización por bloques, Issurin).
- 8–16 semanas: bloques de 4 semanas con foco decreciente en volumen y creciente en intensidad.
- < 8 semanas: mesociclo único de realización + *taper*.
- Deporte de equipo en temporada: mesociclos de mantenimiento de 3–4 semanas anclados al calendario de partidos, con microciclo semanal fijo.

**Etapa 3 — Duración y patrón de microciclos.** Por defecto 4 semanas con patrón de carga `3:1` (tres de carga ascendente, una de descarga al 55–65 % del volumen máximo del bloque). Para principiantes o atletas > 40 años, patrón `2:1`. En temporada, el microciclo se alinea al ciclo de partido (MD-4, MD-3, MD-2, MD-1, MD, MD+1, MD+2).

**Etapa 4 — Distribución de cualidades en la semana.** Reglas de interferencia y recuperación:

- Trabajo de velocidad y potencia siempre antes de fuerza y de resistencia en la misma sesión, y en días con `readiness` alto.
- 48–72 h entre sesiones de alta demanda excéntrica sobre el mismo grupo muscular.
- Resistencia de alta intensidad y fuerza máxima separadas ≥ 6 h; si comparten sesión, la fuerza va primero (efecto de interferencia).
- Máximo 2 sesiones de alta intensidad consecutivas; la tercera exige día de baja carga.
- Día previo a competencia de importancia ≥ 4: solo activación (< 30 min, RPE ≤ 5).

**Etapa 5 — Asignación de sesiones a ventanas.** Problema de asignación resuelto con búsqueda voraz + refinamiento local: maximiza la suma de (prioridad de cualidad × ajuste de la ventana) sujeto a las restricciones de la etapa 4, duración disponible y equipamiento de cada ventana.

**Etapa 6 — Selección de ejercicios.** Para cada bloque de sesión se filtra el catálogo por patrón requerido, equipamiento de la ventana, contraindicaciones activas (`training_restrictions`) y nivel técnico del atleta; se puntúa por especificidad respecto al perfil de demanda de la posición, historial de adherencia y variación respecto al mesociclo anterior (rotación del 30 % de accesorios entre bloques, ejercicios principales estables).

**Etapa 7 — Prescripción de parámetros.** Series, repeticiones e intensidad salen de la plantilla del mesociclo (§6.4) y se resuelven a valores absolutos: `load_kg = %1RM × 1RM_vigente`, con 1RM estimado por Epley cuando solo hay submáximos: `1RM = peso × (1 + reps/30)` (válido hasta ~10 repeticiones).

**Etapa 8 — Verificación y publicación.** Se recalcula la carga interna planificada de la semana, se contrasta con los guardarraíles (§6.6), se corrige si excede, y se persiste el plan junto con una `decision` de tipo `plan_generation` que incluye el snapshot completo de entradas.

## 6.3 Pseudocódigo del generador

```python
def generate_plan(athlete, horizon, ruleset) -> Plan:
    ctx      = build_context(athlete)                  # E1
    peaks    = locate_peaks(ctx.calendar, min_importance=4)
    meso_seq = build_mesocycle_sequence(ctx.goal, peaks, horizon, ruleset)   # E2

    plan = Plan(athlete_id=athlete.id, ruleset_version=ruleset.version)

    for meso in meso_seq:
        micros = split_into_microcycles(meso, pattern=ruleset.wave(ctx.level))  # E3
        for micro in micros:
            qualities = weekly_quality_distribution(meso.focus, ctx.sport, micro.pattern)  # E4
            slots     = assign_to_windows(qualities, ctx.availability, ruleset.spacing)    # E5
            for slot in slots:
                blocks = []
                for req in slot.block_requirements:
                    exercises = select_exercises(req, ctx.restrictions,
                                                 slot.equipment, ctx.history)             # E6
                    blocks.append(prescribe(exercises, meso.focus, micro.ordinal,
                                            ctx.one_rm, ctx.level))                        # E7
                slot.session = Session(blocks=blocks,
                                       planned_load_au=estimate_load(blocks))
            micro.sessions = [s.session for s in slots]
            enforce_guardrails(micro, ctx.load_history, ruleset)                            # E8
        plan.add(meso, micros)

    log_decision(kind="plan_generation", inputs=ctx.snapshot(),
                 rules_fired=ruleset.trace(), subject=plan)
    return plan
```

## 6.4 Plantillas de mesociclo

Parámetros por foco de bloque (progresión semanal dentro del mesociclo; la semana 4 es descarga).

| Foco | Cualidad | Series × Reps | Intensidad | RIR objetivo | Densidad semanal |
|---|---|---|---|---|---|
| Acumulación | Hipertrofia / base | 4×8 → 4×10 → 5×10 → 3×8 | 65–75 % 1RM | 3 → 2 → 1 → 3 | 3–4 sesiones fuerza |
| Acumulación | Resistencia aeróbica | 40–70 min | 65–80 % FCmáx | — | 3–5 sesiones |
| Transmutación | Fuerza máxima | 5×5 → 5×4 → 4×3 → 3×5 | 80–90 % 1RM | 2 → 2 → 1 → 3 | 3 sesiones |
| Transmutación | Umbral / VO₂máx | 4×4 min a 90–95 % FCmáx | alta | — | 2 sesiones clave |
| Realización | Potencia / velocidad | 4×3 → 5×2 → 3×2 | 30–60 % 1RM a máxima velocidad; pérdida de velocidad ≤ 10 % | — | 2–3 sesiones |
| Realización | Velocidad máxima | 6–10×20–40 m | 95–100 % | — | 2 sesiones, recuperación completa |
| *Taper* | Mantenimiento | Volumen −40 a −60 % en 8–14 días | intensidad mantenida | 2 | frecuencia mantenida |
| Transición | Recuperación activa | libre | RPE ≤ 5 | — | 2–3 sesiones |

**Progresión de carga entre mesociclos:** incremento del volumen máximo del bloque entre +2,5 % y +7,5 % respecto al bloque homólogo anterior, condicionado a que la adherencia del bloque previo haya sido ≥ 80 % y no se hayan disparado banderas rojas.

## 6.5 Regulación diaria

Cada mañana, tras el cálculo de `daily_load_metrics`, el motor evalúa la sesión del día:

| Banda de readiness | Rango | Acción sobre la sesión |
|---|---|---|
| Verde | ≥ 75 | Sesión sin cambios. Se permite subir intensidad ≤ 2,5 % si RIR reportado el día previo fue superior al objetivo |
| Verde-atenuado | 65–74 | Sesión sin cambios en intensidad; volumen accesorio −10 % opcional |
| Ámbar | 50–64 | Volumen −20 a −30 %, intensidad mantenida (se preserva el estímulo neural, se recorta el metabólico) |
| Ámbar bajo | 40–49 | Sustitución por sesión de baja carga de la misma cualidad; se conserva la técnica, se elimina el trabajo cercano al fallo |
| Rojo | < 40 o bandera crítica | Recuperación activa o descanso; si se repite 3 días, se adelanta la semana de descarga |

Toda modificación produce una `decision` con `rationale_es` redactado en lenguaje del atleta: *"Bajamos el volumen un 25 % porque tu VHR está por debajo de tu rango habitual dos días seguidos y dormiste 5,4 h. La intensidad se mantiene para no perder el estímulo."*

## 6.6 Guardarraíles de seguridad

Reglas duras. El motor **no puede** emitirlas ni el LLM proponerlas; su violación bloquea la publicación del plan.

1. Incremento de carga semanal (UA) ≤ +15 % respecto a la media de las 3 semanas previas, salvo que la carga crónica sea < 4 semanas de antigüedad (atleta nuevo), donde el techo es +10 %.
2. ACWR proyectado del microciclo dentro de 0,8–1,3; se admite hasta 1,5 solo con aprobación explícita de un usuario con rol `s&c_coach`.
3. Monotonía semanal proyectada < 2,0.
4. Sin trabajo de alta velocidad ni excéntrico máximo con restricción activa sobre esa región corporal.
5. Máximo 6 días consecutivos de entrenamiento; el séptimo es descanso o recuperación activa.
6. Menores de 16 años: sin 1RM directo, sin trabajo al fallo, progresión por técnica; se requiere consentimiento de tutor.
7. Cualquier dolor reportado con NRS ≥ 4 durante una sesión bloquea la progresión de esa cualidad hasta revisión humana (`requires_review = true`).
8. Toda etapa de RTP exige `cleared_by` de un usuario con rol `physio` o `physician`; el sistema nunca autoriza el retorno por sí mismo.

---

# 7. Sistema de scoring de carga y fatiga

## 7.1 Carga interna

**sRPE (métrica canónica, ADR-07).** Recogida entre 10 y 30 minutos después de la sesión, en escala CR-10:

```
carga_sesión_UA = duración_min × sRPE
carga_diaria_UA = Σ carga_sesión_UA del día
```

**TRIMP (secundaria, requiere FC).** Se calcula la variante de Edwards por zonas cuando hay serie de frecuencia cardíaca:

```
TRIMP_Edwards = Σ (minutos_en_zona_i × factor_i),  factor = 1..5 para las zonas 50-60 %…90-100 % FCmáx
```

**Volume load (fuerza).** `Σ (series × repeticiones × kg)`, segmentado por patrón de movimiento y región corporal para detectar desbalances de acumulación.

## 7.2 Carga externa

Normalizada por deporte, con umbrales de velocidad configurables en `sports.demands`:

| Métrica | Definición por defecto |
|---|---|
| Distancia total | metros recorridos |
| HSR | distancia > 19,8 km/h (fútbol/rugby); ajustable por posición |
| Sprint | distancia > 25,2 km/h |
| Aceleraciones / desaceleraciones | eventos > 3 m/s² y < −3 m/s² |
| PlayerLoad | Σ vector de aceleración triaxial normalizado |

**Índice de carga externa compuesto:** `external_load_au = 0,4·z(distancia) + 0,3·z(HSR) + 0,3·z(acel+decel)`, con puntuaciones z calculadas sobre la línea base de 8 semanas del propio atleta (nunca contra la media del equipo).

## 7.3 Carga aguda, crónica y ACWR

```
aguda_7d   = Σ carga_diaria_UA de los últimos 7 días
crónica_28d = (Σ carga_diaria_UA de los últimos 28 días) / 4
ACWR_RA    = aguda_7d / crónica_28d
```

**Variante EWMA (preferida, Williams y cols. 2017)** porque pondera lo reciente y no trata los 28 días como una ventana plana:

```
λ_a = 2/(7+1) = 0,25      λ_c = 2/(28+1) ≈ 0,069
EWMA_hoy = carga_hoy × λ + EWMA_ayer × (1 − λ)
ACWR_EWMA = EWMA_aguda / EWMA_crónica
```

Se calculan y almacenan ambas. **El ACWR no se muestra al atleta como número**: alimenta las bandas de §7.9 y se expone al staff técnico con su intervalo de confianza y el aviso metodológico de §1.1. Requisito mínimo: 21 días de datos para emitir ACWR; por debajo, `hrv_status = 'insufficient_data'` y el ratio no se reporta.

## 7.4 Monotonía y strain (Foster)

```
monotonía = media(carga_diaria_UA, 7d) / DE(carga_diaria_UA, 7d)
strain    = carga_semanal_UA × monotonía
```

Monotonía > 2,0 indica una semana plana, sin oscilación entre días duros y suaves: es un objetivo directo del planificador, que introduce variabilidad antes de reducir volumen total.

## 7.5 Modelo fitness–fatiga

Modelo de respuesta a impulsos (Banister) con dos trazas exponenciales:

```
Fitness_t = Fitness_{t−1} · e^(−1/τ₁) + carga_t        τ₁ = 42 días
Fatiga_t  = Fatiga_{t−1}  · e^(−1/τ₂) + carga_t        τ₂ = 7 días
Forma_t   = k₁ · Fitness_t − k₂ · Fatiga_t             k₁ = 1, k₂ = 2 (por defecto)
```

Las constantes son ajustables por atleta a partir de 12 semanas de datos, minimizando el error contra los resultados de tests de §4.5. Hasta entonces se usan los valores por defecto y se marca el modelo como no calibrado.

## 7.6 Variabilidad de la frecuencia cardíaca

Se trabaja con `ln rMSSD` (la transformación logarítmica estabiliza la varianza), medición matutina en supino o media de sueño, siempre con el mismo protocolo por atleta.

```
línea_base   = media móvil de 7 días de ln rMSSD
SWC          = línea_base ± 0,5 × DE(ln rMSSD de 30 días)
CV_semanal   = DE(7d) / media(7d) × 100
```

Interpretación operativa: valor dentro del SWC → normal; por debajo del límite inferior dos días consecutivos → señal de fatiga acumulada; CV semanal creciente con línea base descendente → bandera ámbar. Una sola lectura baja aislada **no** modifica el plan.

## 7.7 Índice de readiness

Puntuación 0–100, combinación ponderada de componentes normalizados a z-score contra la línea base individual de 30 días, luego re-escalados:

| Componente | Peso | Fuente | Nota |
|---|---|---|---|
| VHR (ln rMSSD vs. SWC) | 25 % | `hrv_readings` | Redistribuido si no hay datos |
| Sueño (duración × eficiencia) | 20 % | `sleep_records` o autoinforme | |
| Fatiga percibida | 15 % | `wellness_entries` | |
| Dolor muscular | 15 % | `wellness_entries` + mapa corporal | Ponderado por región implicada en la sesión del día |
| Estrés y ánimo | 10 % | `wellness_entries` | |
| Estado de carga (ACWR + strain) | 10 % | `daily_load_metrics` | |
| Frecuencia cardíaca en reposo | 5 % | wearable | |

```
readiness = 100 × Σ (peso_i × componente_normalizado_i) / Σ pesos_disponibles
```

**Manejo de datos faltantes:** los pesos de los componentes ausentes se redistribuyen proporcionalmente. Si `data_completeness_pct < 50`, el índice no se emite: la app muestra "datos insuficientes" y el plan sigue sin ajuste automático. Nunca se imputa un valor silenciosamente.

## 7.8 Señales de gestión de riesgo

Capa de reglas explícitas (v1 del ruleset), no un modelo predictivo:

| Bandera | Condición | Severidad |
|---|---|---|
| `ACWR_HIGH` | ACWR_EWMA > 1,5 con ≥ 21 días de datos | media |
| `ACWR_LOW` | ACWR_EWMA < 0,8 durante ≥ 10 días (desentrenamiento) | baja |
| `SPIKE` | Carga semanal > +30 % respecto a la media de 3 semanas | alta |
| `MONOTONY` | Monotonía > 2,0 y strain en el percentil 90 individual | media |
| `HRV_SUPPRESSED` | ln rMSSD < SWC inferior 3 días de 5 | media |
| `SLEEP_DEBT` | < 6 h de media en 5 días | media |
| `PAIN` | NRS ≥ 4 en una región, o ≥ 2 durante 3 días | alta |
| `RECENT_INJURY` | Lesión en la misma región en los últimos 90 días con carga en ascenso | alta |
| `LOW_CHRONIC` | Carga crónica < percentil 25 del deporte con retorno a competición | alta |

A partir de Fase 3, un modelo de gradient boosting entrenado con datos propios produce una puntuación adicional; **se despliega en modo sombra durante al menos una temporada** y solo pasa a producción si supera a la línea base de reglas en calibración (curva de fiabilidad, Brier score) sobre datos de validación temporal.

## 7.9 Lenguaje de la interfaz

Norma de producto, no sugerencia. Se muestra:

- ✅ "Tu carga subió más rápido de lo habitual esta semana" / "Tu VHR lleva dos días por debajo de tu rango normal"
- ✅ "Recomendación: reducir volumen hoy y revisar el sueño"
- ❌ "Riesgo de lesión: 34 %" / "Estás lesionado" / "Tu cuerpo no está listo"

Cada bandera se acompaña siempre de la evidencia que la disparó y de la acción concreta propuesta.

---

# 8. Especificación de APIs

## 8.1 Convenciones transversales

| Aspecto | Decisión |
|---|---|
| Estilo | REST sobre HTTPS, JSON; OpenAPI 3.1 como fuente de verdad (contract-first) |
| Base | `https://api.plataforma.app/v1` — versión en la ruta; cambios incompatibles solo en versión mayor |
| Autenticación | OAuth 2.1 + OIDC; *access token* JWT de 15 min, *refresh* rotativo de 30 días ligado al dispositivo |
| Autorización | *Scopes* por rol (`athlete:read`, `plan:write`, `team:read`) + RLS en base de datos como segunda barrera |
| Errores | RFC 9457 `application/problem+json` |
| Paginación | Cursor opaco: `?limit=50&cursor=...`; respuesta con `next_cursor` |
| Idempotencia | Cabecera `Idempotency-Key` obligatoria en todos los `POST` mutantes; retención 24 h |
| Concurrencia | `ETag` + `If-Match` en recursos editables (plan, sesión) |
| Fechas | ISO 8601 con zona; el cuerpo incluye `timezone` del atleta cuando la fecha es "día de entrenamiento" |
| Límite de tasa | 600 req/min por usuario; 60 req/min en endpoints de IA; cabeceras `RateLimit-*` |
| Trazabilidad | `X-Request-Id` propagado; devuelto en toda respuesta y en el problema de error |

Formato de error:

```json
{
  "type": "https://api.plataforma.app/problems/guardrail-violation",
  "title": "La modificación excede los límites de seguridad de carga",
  "status": 422,
  "detail": "El incremento solicitado (+28 %) supera el máximo permitido (+15 %).",
  "instance": "/v1/plans/9f1c.../sessions/4ab2...",
  "request_id": "01J8ZP...",
  "violations": [{ "rule": "WEEKLY_LOAD_INCREASE", "limit": 0.15, "value": 0.28 }]
}
```

## 8.2 Catálogo de endpoints

### Identidad y atleta

| Método | Ruta | Descripción |
|---|---|---|
| `POST` | `/auth/register` | Alta de usuario |
| `POST` | `/auth/token` | Login / refresh |
| `POST` | `/auth/mfa/verify` | Verificación de segundo factor |
| `GET` | `/me` | Perfil del usuario autenticado con roles |
| `POST` | `/athletes` | Crear perfil de atleta |
| `GET` `PATCH` | `/athletes/{id}` | Leer / actualizar perfil |
| `POST` | `/athletes/{id}/anthropometrics` | Registrar medición |
| `GET` | `/athletes/{id}/anthropometrics?from=&to=` | Serie histórica |
| `PUT` | `/athletes/{id}/availability` | Reemplazar disponibilidad semanal |
| `GET` `POST` | `/athletes/{id}/goals` | Objetivos |
| `GET` `POST` | `/athletes/{id}/calendar-events` | Competencias y bloqueos |
| `POST` | `/athletes/{id}/consents` | Otorgar o revocar consentimiento |

### Evaluación

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/tests` | Catálogo de tests con protocolos |
| `POST` | `/athletes/{id}/test-results` | Registrar resultado (lote permitido) |
| `GET` | `/athletes/{id}/test-results?test=&from=` | Histórico con percentiles |
| `POST` | `/athletes/{id}/assessments/initial` | Ejecutar batería inicial y devolver perfil |
| `GET` | `/athletes/{id}/one-rm` | 1RM vigentes (medidos y estimados) por ejercicio |

### Planificación

| Método | Ruta | Descripción |
|---|---|---|
| `POST` | `/plans` | Generar plan (`athlete_id`, `goal`, `horizon_weeks`, `target_event_id`) |
| `GET` | `/plans/{id}` | Plan completo con jerarquía meso/micro/sesión |
| `POST` | `/plans/{id}:approve` | Aprobación del staff (obligatoria en organizaciones con rol coach) |
| `POST` | `/plans/{id}:regenerate` | Regenerar desde una fecha, preservando el historial |
| `GET` | `/athletes/{id}/sessions?from=&to=` | Agenda de sesiones |
| `GET` | `/sessions/{id}` | Sesión con bloques e ítems prescritos resueltos |
| `POST` | `/sessions/{id}:adjust` | Ajuste manual (valida guardarraíles, crea `decision`) |
| `POST` | `/sessions/{id}:swap` | Sustituir por sesión equivalente (equipamiento, tiempo, dolor) |
| `GET` | `/sessions/{id}/alternatives` | Alternativas válidas para el contexto actual |

### Ejecución

| Método | Ruta | Descripción |
|---|---|---|
| `POST` | `/executions` | Iniciar sesión ejecutada |
| `POST` | `/executions/{id}/sets` | Registrar serie (lote, apto para uso offline) |
| `POST` | `/executions/{id}:complete` | Cerrar sesión con `session_rpe` y feedback |
| `POST` | `/executions/{id}/pain-report` | Reportar dolor (dispara evaluación de riesgo) |
| `POST` | `/sync/batch` | Sincronización diferida de registros creados sin conexión |

### Bienestar y métricas

| Método | Ruta | Descripción |
|---|---|---|
| `PUT` | `/athletes/{id}/wellness/{date}` | Cuestionario diario (idempotente por fecha) |
| `POST` | `/athletes/{id}/hrv` | Lectura de VHR manual o de dispositivo |
| `GET` | `/athletes/{id}/metrics/daily?from=&to=` | Serie de `daily_load_metrics` |
| `GET` | `/athletes/{id}/readiness/today` | Readiness del día, con desglose por componente |
| `GET` | `/athletes/{id}/load-summary?window=weekly` | Resumen de carga, ACWR, monotonía, forma |
| `GET` | `/athletes/{id}/risk-flags?active=true` | Banderas activas con evidencia |

### Integraciones

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/integrations/providers` | Proveedores disponibles y *scopes* requeridos |
| `POST` | `/integrations/{provider}/connect` | Iniciar OAuth, devuelve URL de autorización |
| `GET` | `/integrations/{provider}/callback` | Callback OAuth |
| `DELETE` | `/integrations/{provider}` | Revocar conexión y purgar tokens |
| `POST` | `/integrations/{provider}/sync` | Forzar sincronización de una ventana |
| `POST` | `/webhooks/{provider}` | Recepción de eventos push del proveedor (firma verificada) |

### IA conversacional

| Método | Ruta | Descripción |
|---|---|---|
| `POST` | `/ai/conversations` | Abrir conversación con contexto |
| `POST` | `/ai/conversations/{id}/messages` | Enviar mensaje; respuesta en streaming SSE |
| `GET` | `/ai/conversations/{id}` | Historial |
| `POST` | `/ai/interpret` | Convertir texto libre en intención estructurada sin efectos secundarios |

### Decisiones y auditoría

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/athletes/{id}/decisions?from=&kind=` | Log de decisiones |
| `GET` | `/decisions/{id}` | Decisión con entradas, reglas disparadas y explicación |
| `POST` | `/decisions/{id}:review` | Aceptar, anular o rechazar (staff) |
| `GET` | `/rulesets` `POST /rulesets` | Consultar y publicar versiones de reglas (admin) |

### Club y equipo (Fase 4)

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/teams/{id}/load-board?date=` | Tablero de carga y readiness del plantel |
| `GET` | `/teams/{id}/availability` | Disponibilidad y estado de lesión por atleta |
| `POST` | `/teams/{id}/sessions` | Sesión colectiva con individualización automática |
| `GET` | `/teams/{id}/reports/weekly` | Informe semanal exportable |
| `POST` | `/organizations/{id}/athletes:bulk-import` | Alta masiva (CSV) |

## 8.3 Ejemplos de contrato

**Generación de plan**

```http
POST /v1/plans
Idempotency-Key: 6f9d2a41-...
Content-Type: application/json

{
  "athlete_id": "0192f3a1-...",
  "primary_goal": "sport_performance",
  "secondary_goals": ["strength"],
  "horizon_weeks": 16,
  "target_event_id": "0192f7c5-...",
  "constraints": {
    "max_sessions_per_week": 5,
    "equipment_context": "full_gym",
    "excluded_exercises": ["back_squat"]
  }
}
```

```json
201 Created
{
  "plan_id": "0192fa03-...",
  "status": "draft",
  "generator_version": "planner-2.1.0",
  "ruleset_version": "rs-2026.08",
  "data_completeness_pct": 82.0,
  "requires_review": false,
  "summary": {
    "mesocycles": 4,
    "weekly_load_au": [1850, 2010, 2180, 1290],
    "projected_acwr_peak": 1.24
  },
  "decision_id": "0192fa04-...",
  "warnings": [
    { "code": "MISSING_1RM", "detail": "Sin 1RM de peso muerto: se prescribe por RIR en las 2 primeras semanas." }
  ]
}
```

**Readiness del día**

```json
GET /v1/athletes/0192f3a1-.../readiness/today

{
  "date": "2026-08-19",
  "score": 58.4,
  "band": "amber",
  "data_completeness_pct": 86.0,
  "components": [
    { "key": "hrv",       "weight": 0.25, "z": -1.42, "status": "below_swc" },
    { "key": "sleep",     "weight": 0.20, "z": -0.90, "value_min": 324 },
    { "key": "fatigue",   "weight": 0.15, "z": -0.60 },
    { "key": "soreness",  "weight": 0.15, "z": -0.30, "regions": ["hamstring_left"] },
    { "key": "load_state","weight": 0.10, "z": -0.75, "acwr_ewma": 1.38 }
  ],
  "flags": ["HRV_SUPPRESSED", "SLEEP_DEBT"],
  "recommended_action": {
    "type": "reduce_volume",
    "factor": 0.75,
    "keep_intensity": true,
    "rationale_es": "Tu VHR está por debajo de tu rango normal dos días seguidos y dormiste 5,4 h de media. Mantenemos la intensidad y bajamos el volumen un 25 %."
  }
}
```

## 8.4 Herramientas expuestas al orquestador de IA

El LLM opera exclusivamente mediante estas herramientas tipadas. No tiene acceso a la base de datos ni puede escribir prescripciones fuera de ellas.

| Herramienta | Efecto | Requiere confirmación del usuario |
|---|---|---|
| `get_athlete_context()` | Lectura de perfil, plan vigente, métricas | No |
| `get_todays_session()` | Lectura | No |
| `explain_decision(decision_id)` | Lectura del log | No |
| `propose_session_adjustment(session_id, reason, params)` | Propuesta validada contra guardarraíles; devuelve aceptada o rechazada con motivo | Sí |
| `swap_session(session_id, constraint)` | Sustitución dentro de alternativas válidas | Sí |
| `log_wellness(date, fields)` | Escritura acotada | No |
| `log_pain(region, nrs, context)` | Escritura + disparo de evaluación de riesgo | No |
| `search_exercise_library(query, filters)` | Lectura | No |
| `escalate_to_human(reason)` | Notifica al staff | No |

**Guardarraíles del orquestador:** sin consejo médico ni nutricional clínico (se deriva a profesional); mensajes que sugieran lesión aguda, dolor torácico o síntomas de alarma cortan la conversación y activan `escalate_to_human`; nunca se contradicen los guardarraíles de §6.6; toda propuesta aceptada genera una `decision` con `llm_model` registrado.

## 8.5 Webhooks salientes (clientes empresariales, Fase 4)

`POST` firmado con HMAC-SHA256 (`X-Signature`, tolerancia de 5 min): `athlete.risk_flag.raised`, `athlete.session.completed`, `team.weekly_report.ready`. Reintentos con retroceso exponencial durante 24 h; cola muerta consultable desde el back-office.

---

# 9. Seguridad, privacidad y cumplimiento

## 9.1 Clasificación de datos

Los datos de VHR, sueño, lesiones y percepción de dolor son **datos de salud** (categoría especial, art. 9 RGPD; ley 25.326 en Argentina). Consecuencias vinculantes: base legal por consentimiento explícito y granular, minimización, cifrado en reposo y evaluación de impacto (DPIA) antes del lanzamiento público.

## 9.2 Controles técnicos

- TLS 1.3 en tránsito; AES-256 en reposo; tokens de wearables cifrados por sobre con claves en KMS y rotación trimestral.
- Secretos fuera del repositorio (Vault o gestor del proveedor cloud); escaneo de secretos en CI.
- Aislamiento por RLS con `app.user_id` fijado por el gateway a partir del JWT verificado.
- MFA obligatorio para roles con acceso multi-atleta (coach, physio, admin).
- Registro de auditoría inmutable para todo acceso a datos de otro sujeto: quién, cuándo, qué atleta, con qué fin.
- Pruebas de penetración anuales y revisión de dependencias en cada build.

## 9.3 Derechos del interesado

Endpoints y procesos para acceso, rectificación, portabilidad (exportación JSON + CSV completa), oposición y supresión. La supresión ejecuta anonimización irreversible en 30 días y propaga la revocación a los proveedores de wearables conectados.

## 9.4 Datos de menores y contexto de club

Menores de 16 años: consentimiento del tutor verificado, funcionalidades restringidas (§6.6.6) y visibilidad limitada. En clubes, el atleta conserva la titularidad de sus datos de salud: el staff ve carga, disponibilidad y banderas; el detalle clínico requiere permiso específico por rol y queda auditado.

---

# 10. Calidad, pruebas y observabilidad

| Nivel | Alcance | Umbral |
|---|---|---|
| Unitarias | Fórmulas de carga, ACWR, readiness, estimación de 1RM | Cobertura ≥ 90 % en el paquete de dominio |
| Propiedades | Invariantes del generador (nunca supera guardarraíles, nunca prescribe ejercicio contraindicado) | Hypothesis, 1000 casos por invariante |
| Golden tests | 30 perfiles sintéticos de atleta con plan esperado versionado | Diferencia = fallo, revisión obligatoria |
| Integración | Contratos entre servicios (Pact), migraciones, RLS | Bloqueante en CI |
| E2E | Alta → evaluación → plan → ejecución → ajuste | Detox (móvil), Playwright (web) |
| Carga | 10 000 atletas, cálculo nocturno de métricas | p95 < 300 ms lectura; ventana batch < 20 min |
| Validación científica | Revisión del ruleset por el consejo asesor deportivo antes de publicar | Firma registrada en `rulesets.published_by` |

**Métricas de producto a instrumentar desde el día uno:** adherencia al plan (sesiones completadas / prescritas), tasa de cumplimiento del cuestionario diario, latencia de sincronización de wearables, proporción de decisiones anuladas por el staff (indicador de calidad del motor) y retención a 4, 8 y 12 semanas.

---

# 11. Roadmap por fases

## Fase 0 — Fundaciones (4 semanas)

Preparación, no producto. Repositorio, CI/CD, entornos, esquema base y migraciones, autenticación, observabilidad, **ruleset v1 escrito y revisado por el consejo deportivo**, catálogo inicial de 250 ejercicios y catálogo de tests. *Criterio de salida:* pipeline verde de extremo a extremo con un despliegue automático en `staging`.

## Fase 1 — MVP (12–16 semanas)

**Objetivo:** un atleta individual recibe un plan semanal coherente, lo ejecuta y ve que el plan reacciona.

Alcance funcional: registro y onboarding; evaluación inicial (batería reducida: CMJ, sprint 10/30 m, test de fuerza estimado, Yo-Yo o Course Navette, cuestionario de historial); generación de plan de 4–8 semanas; agenda y ejecución de sesión con registro de series; sRPE post-sesión; cuestionario diario de bienestar; ajuste diario por readiness (versión con wellness manual, VHR opcional); dashboard de progreso; chat con IA acotado a lectura y a las herramientas de §8.4 marcadas sin confirmación; integración con **Apple Health y Garmin**; modo offline con sincronización diferida.

Alcance técnico: monolito modular, PostgreSQL único, cálculo de métricas en job nocturno + recálculo bajo demanda, sin bus de eventos (llamadas internas).

Deportes: **fuerza y running** completos; rugby, fútbol y hockey con plantillas genéricas de pretemporada.

*Criterios de salida:* 100 atletas en beta cerrada; adherencia ≥ 60 % a 4 semanas; ≥ 70 % de días con cuestionario completado; cero violaciones de guardarraíles en producción; NPS ≥ 30.

## Fase 2 — Beta pública (10–14 semanas)

**Objetivo:** rigor científico completo y escala.

Añade: VHR con línea base y SWC, modelo fitness–fatiga, ACWR EWMA y monotonía/strain completos; periodización por bloques con calendario competitivo y *taper*; plantillas específicas por deporte y posición para los cinco deportes; integración con Polar, WHOOP y Fitbit; log de decisiones expuesto al usuario ("¿por qué esta sesión?"); biblioteca de ejercicios con vídeo; extracción de `integration-service`, `load-analytics-service` y `ai-orchestrator` a servicios propios; bus de eventos con outbox; suscripción de pago.

*Criterios de salida:* 2 000 usuarios activos; retención a 12 semanas ≥ 35 %; p95 de API < 300 ms; < 2 % de decisiones anuladas por error del motor; auditoría de seguridad superada.

## Fase 3 — Profesional (12–16 semanas)

**Objetivo:** herramienta de trabajo para entrenador y atleta de alto rendimiento.

Añade: rol entrenador con cartera de atletas y aprobación de planes; edición manual de planes con validación de guardarraíles; ingesta de GPS/LPS (Catapult, STATSports, WIMU) y carga externa completa; entrenamiento basado en velocidad (VBT) con umbrales de pérdida de velocidad; flujo de RTP con etapas y validación de fisioterapeuta; informes exportables PDF/CSV; ClickHouse para analítica; modelo de ML de riesgo **en modo sombra**; API pública documentada y webhooks.

*Criterios de salida:* 25 entrenadores profesionales activos; ≥ 8 atletas de media por entrenador; tiempo de creación de plan < 5 min frente a la línea base manual; modelo sombra con calibración documentada.

## Fase 4 — Clubes y federaciones (16–20 semanas)

**Objetivo:** gestión de plantel completo con gobierno de datos.

Añade: multi-equipo y multi-temporada; tablero de carga y disponibilidad del plantel; sesiones colectivas con individualización automática por posición y estado; planificación semanal alineada al ciclo de partido (MD-x); permisos granulares por rol (médico, físico, analista, técnico); importación masiva y SSO empresarial (SAML/SCIM); comparativas contra normas de posición; facturación por asientos; SLA y soporte; residencia de datos por región.

*Criterios de salida:* 3 clubes con plantel completo en producción durante una temporada; disponibilidad ≥ 99,5 %; auditoría de cumplimiento superada.

## 11.1 Resumen

| Fase | Duración | Foco | Equipo mínimo |
|---|---|---|---|
| 0 | 4 sem | Fundaciones | 1 arquitecto, 1 backend, 1 DevOps, 1 científico del deporte |
| 1 | 12–16 sem | MVP individual | 2 backend, 2 móvil, 1 diseño, 1 ciencia del deporte, 1 QA |
| 2 | 10–14 sem | Rigor + escala | +1 backend, +1 datos, +1 ML |
| 3 | 12–16 sem | Profesional | +1 frontend web, +1 datos, +1 soporte |
| 4 | 16–20 sem | Clubes | +2 backend, +1 SRE, +1 éxito de cliente |

---

# 12. Riesgos y mitigaciones

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Baja adherencia al cuestionario diario deja el motor sin entradas | Alto | Cuestionario de 20 segundos; degradación explícita con pesos redistribuidos; recordatorios contextuales, no genéricos |
| APIs de wearables inestables o con cambios de contrato | Alto | Payloads crudos persistidos y reprocesables; capa de normalización por proveedor con pruebas de contrato; degradación a entrada manual |
| Sobreconfianza en el ACWR | Medio-alto | Nunca como número al atleta; combinación de señales; aviso metodológico al staff (§1.1) |
| Deriva del LLM hacia consejo clínico | Alto | Herramientas tipadas, guardarraíles duros, escalado a humano, evaluación adversarial en cada release del prompt |
| Coste de inferencia con escala | Medio | Caché de contexto, modelos pequeños para intención y grandes solo para explicación, presupuesto por usuario |
| Complejidad prematura de microservicios | Medio | ADR-04: monolito modular hasta Fase 2 |
| Cumplimiento de datos de salud | Alto | DPIA previa al lanzamiento, consentimiento granular, cifrado, auditoría, asesoría legal por jurisdicción |

---

# 13. Anexos

## 13.1 Fórmulas de referencia

| Concepto | Fórmula |
|---|---|
| Carga interna de sesión | `duración_min × sRPE` |
| ACWR (media móvil) | `carga_7d / (carga_28d / 4)` |
| ACWR (EWMA) | `EWMA_t = carga_t·λ + EWMA_{t−1}·(1−λ)`, `λ = 2/(N+1)` |
| Monotonía | `media_semanal / DE_semanal` |
| Strain | `carga_semanal × monotonía` |
| Fitness / Fatiga | `X_t = X_{t−1}·e^(−1/τ) + carga_t`, `τ = 42 / 7 días` |
| 1RM (Epley) | `peso × (1 + reps/30)` |
| 1RM (Brzycki) | `peso / (1,0278 − 0,0278 × reps)` |
| SWC de VHR | `media_7d ± 0,5 × DE_30d` (sobre `ln rMSSD`) |
| FCmáx estimada | `208 − 0,7 × edad` (Tanaka) — solo si no hay test directo |
| Velocidad aeróbica máxima | de test de campo (Course Navette, Yo-Yo IR1) |

## 13.2 Base científica del ruleset v1

Periodización por bloques (Issurin); carga interna y monotonía (Foster); ACWR y sus críticas (Gabbett; Impellizzeri y cols.; Bahr); modelo de respuesta a impulsos (Banister); VHR aplicada al entrenamiento (Plews y Buchheit); *taper* (Mujika y Padilla); autorregulación por RIR (Zourdos y cols.); prevención de lesiones de isquiotibiales (protocolo nórdico) y programas de calentamiento neuromuscular (FIFA 11+). Cada regla del `ruleset` DEBE llevar en su JSON un campo `reference` con la cita que la respalda, para que la revisión científica sea verificable.

## 13.3 Prompt de sistema del orquestador de IA (extracto normativo)

> Sos el asistente deportivo de la plataforma. Trabajás para un atleta concreto, cuyo contexto obtenés siempre con `get_athlete_context()` antes de responder. **No prescribís cargas por tu cuenta**: para cualquier cambio en el entrenamiento llamás a `propose_session_adjustment` o `swap_session` y comunicás lo que el motor haya aceptado o rechazado, con su motivo. No das diagnósticos ni consejo médico o nutricional clínico; ante síntomas de alarma, dolor agudo o señales de lesión, llamás a `escalate_to_human`. Hablás en el idioma del atleta, en segunda persona, breve y concreto. Cuando expliques una decisión, citá la evidencia (métrica, valor, umbral). Si faltan datos, decilo en vez de suponer.

## 13.4 Trazabilidad con la v1

| Requisito v1 | Dónde se especifica en v2 |
|---|---|
| Rutinas individualizadas | §6.2 etapas 4–7, §4.6 |
| Periodización macro/meso/micro | §6.2, §4.6 |
| Gestión de carga interna y externa | §7.1, §7.2, §4.9 |
| Monitoreo de recuperación, sueño, estrés, fatiga | §4.8, §7.6, §7.7 |
| Estimación de riesgo y ajuste automático | §7.8, §6.5, con la salvedad de §1.1 |
| Integración con wearables | §4.12, §5.2, §8.2 |
| IA que interpreta lenguaje natural | §8.4, §13.3 |
| Recomendaciones adaptativas diarias | §6.5 |
| Trazabilidad de decisiones | §4.11, §8.2 |
| Cinco deportes iniciales | §4.4, Fases 1–2 |

---

*Fin del documento. La versión editable en Markdown vive en el repositorio (`docs/especificacion-tecnica-v2.md`) y es la fuente de verdad; el `.docx` se genera a partir de ella.*
