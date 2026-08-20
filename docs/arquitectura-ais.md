---
title: "Athlete Intelligence System"
subtitle: "Arquitectura técnica v1.0 — previa a la implementación"
author: "Tomás Juárez"
date: "20 de agosto de 2026"
lang: es
toc-title: "Índice"
---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# 0. Antes de empezar: qué cambia respecto de la especificación v2

Esta arquitectura responde al brief de *Athlete Intelligence System* (AIS). Hay una diferencia real con la Especificación Técnica v2.0 que conviene resolver ahora y no a mitad del desarrollo:

| Aspecto | Especificación v2.0 | Brief AIS | Resolución adoptada |
|---|---|---|---|
| Ejecución | Backend FastAPI + PostgreSQL | React + TypeScript, localStorage | **Client-first.** Toda la lógica vive en TypeScript en el navegador |
| Persistencia | PostgreSQL con RLS | localStorage → Supabase | localStorage detrás de una interfaz de repositorio; Supabase es un adaptador más |
| Despliegue | Microservicios en Kubernetes | Aplicación web | Un solo artefacto estático. Los microservicios pasan a ser un escenario posterior, no el punto de partida |
| Producto | App de entrenamiento | Sistema de evaluación y decisión | **Manda el brief**: la rutina es una salida, no el producto |

Lo que **no** cambia y se conserva íntegro: el modelo de dominio deportivo (carga interna y externa, ACWR, monotonía, fitness–fatiga, readiness), los guardarraíles de seguridad y la trazabilidad de decisiones. Esa lógica ya era independiente de la infraestructura; aquí se reescribe en TypeScript puro en lugar de Python, y gana portabilidad: el mismo código corre en el navegador hoy y en un servidor Node mañana sin tocarse.

El esquema PostgreSQL de la v2 no se tira: se convierte en el **destino** del esquema de Supabase (§7.4). Las tablas ya están diseñadas y validadas; lo que cambia es cuándo se adoptan.

## 0.1 Una advertencia sobre el alcance

El brief describe un sistema experto con *digital twin* y aprendizaje continuo. Dos cosas que el equipo debe tener claras desde el día uno, porque determinan qué se puede prometer:

- **Con un solo atleta no hay aprendizaje estadístico.** Un modelo que "aprende con el tiempo" sobre n=1 no generaliza: ajusta constantes personales. Eso es valioso y es honesto llamarlo **calibración individual** (§6.6), no machine learning. El aprendizaje real requiere una población, y llega recién con Supabase y consentimiento explícito.
- **La comparación contra "perfiles deportivos ideales" es tan buena como sus normas.** Un arquetipo inventado produce brechas inventadas. Cada `Archetype` DEBE declarar la procedencia de sus valores (§5.3): estudio publicado, datos propios o estimación del staff. La UI muestra esa procedencia junto a la brecha.

---

# 1. Principio central como arquitectura

El brief define la cadena `Evaluación → Modelado → Diagnóstico → Decisión → Prescripción`. Esa cadena no es una metáfora: es literalmente el flujo de datos del sistema, y cada eslabón es un módulo con entrada y salida tipadas.

```
  Assessment[]          AthleteModel         Gap[] + Diagnosis[]
      │                      │                       │
      ▼                      ▼                       ▼
 ┌──────────┐         ┌────────────┐          ┌────────────┐
 │Evaluación│────────▶│  Modelado  │─────────▶│Diagnóstico │
 └──────────┘         └────────────┘          └────────────┘
  Assessment Lab       Digital Athlete         Decision Engine
                             ▲                       │
                             │                       ▼
                       DailyEntry[]            ┌────────────┐
                             │                 │  Decisión  │
                       ┌────────────┐          └────────────┘
                       │Daily Track.│                 │
                       └────────────┘                 ▼
                             ▲                 ┌────────────┐
                             └─────────────────│Prescripción│
                                 adherencia    └────────────┘
                                                Program Generator
```

Dos propiedades que esta forma garantiza y que hay que defender en cada revisión de código:

1. **Cada eslabón es una función pura de su entrada.** `diagnose(model, target) → Diagnosis[]` no toca la red, ni el reloj, ni el almacenamiento. Se testea con una tabla de casos.
2. **Nada salta eslabones.** La UI no calcula brechas; el generador de programas no lee `Assessment` crudos. Si un módulo necesita un dato que está dos eslabones atrás, el dato pertenece al modelo intermedio y hay que agregarlo ahí.

---

# 2. Arquitectura por capas

## 2.1 Las cinco capas y la regla de dependencia

```
┌───────────────────────────────────────────────────────────┐
│  UI Layer            React, Tailwind, hooks, componentes   │
│                      Sabe de todo lo de abajo              │
├───────────────────────────────────────────────────────────┤
│  Application Layer   Casos de uso, orquestación, stores    │
│                      Sabe de dominio, motor y puertos      │
├───────────────────────────────────────────────────────────┤
│  Decision Engine     Reglas, evaluación, priorización      │
│  Analytics Layer     Métricas, series, tendencias          │
│                      Saben solo de dominio                 │
├───────────────────────────────────────────────────────────┤
│  Domain Layer        Entidades, value objects, invariantes │
│                      No sabe de NADA. Cero imports         │
└───────────────────────────────────────────────────────────┘
        ▲
        │ implementa puertos
┌───────────────────────────────────────────────────────────┐
│  Infrastructure      localStorage, Supabase, wearables     │
└───────────────────────────────────────────────────────────┘
```

**La regla:** las dependencias apuntan hacia adentro. El dominio no importa React, no importa el almacenamiento, no llama a `Date.now()` ni a `Math.random()` — el tiempo y la aleatoriedad entran como parámetros. Esto no es purismo: es lo que permite testear el motor de decisión con 500 casos en milisegundos y reproducir cualquier decisión histórica exactamente.

Se hace cumplir con ESLint, no con buena voluntad:

```js
// .eslintrc — no-restricted-imports por capa
'domain/**':    { patterns: ['react*', '@/infrastructure/*', '@/ui/*', '@/application/*'] },
'decision/**':  { patterns: ['react*', '@/infrastructure/*', '@/ui/*'] },
'analytics/**': { patterns: ['react*', '@/infrastructure/*', '@/ui/*'] },
'application/**': { patterns: ['react*'] }
```

## 2.2 Qué hace cada capa

| Capa | Responsabilidad | Contiene | No contiene |
|---|---|---|---|
| **Domain** | Qué es un atleta, una evaluación, una brecha. Reglas que son verdad siempre | Tipos, constructores validados, value objects, invariantes, unidades | Persistencia, formato de fecha para UI, texto de interfaz |
| **Analytics** | Convertir historial en métricas: ACWR, monotonía, fitness–fatiga, tendencias, z-scores | Funciones puras sobre series temporales | Decisiones. Calcula, no opina |
| **Decision Engine** | Convertir métricas y brechas en diagnósticos, prioridades y acciones | Evaluador de reglas, resolución de conflictos, guardarraíles, trazas | Efectos. Devuelve `Decision[]`, no los aplica |
| **Application** | Casos de uso completos y estado de la app | `runAssessment`, `generateProgram`, `logDay`, stores de Zustand, puertos | Lógica deportiva. Si hay un umbral acá, está en el lugar equivocado |
| **UI** | Presentar y capturar | Componentes, formularios, gráficos, rutas | Cualquier cálculo. Un `if (acwr > 1.3)` en un componente es un bug |
| **Infrastructure** | Hablar con el mundo | Adaptadores localStorage/Supabase, migraciones, importadores | Reglas de negocio |

## 2.3 Puertos y adaptadores

La persistencia entra por interfaces definidas en la capa de aplicación. Esto es lo que hace que el salto de localStorage a Supabase sea un cambio de una línea en el arranque.

```ts
// application/ports/repository.ts

/** K es la clave del agregado: no todos se identifican con un id simple. */
export interface Repository<T, K = string> {
  get(key: K): Promise<T | null>;
  list(filter?: Partial<T>): Promise<T[]>;
  save(entity: T): Promise<void>;
  remove(key: K): Promise<void>;
}

/** DailyEntry no lleva id: su identidad ES el par (atleta, día local). */
export type EntryKey = { readonly athleteId: AthleteId; readonly date: ISODate };

export interface UnitOfWork {
  athletes: Repository<AthleteModel, AthleteId>;
  assessments: Repository<Assessment, AssessmentId>;
  plans: Repository<TrainingPlan, PlanId>;
  entries: Repository<DailyEntry, EntryKey>;
  decisions: Repository<DecisionRecord, DecisionId>;
  archetypes: Repository<Archetype, ArchetypeId>;
  transaction<T>(fn: (uow: UnitOfWork) => Promise<T>): Promise<T>;
}

export interface Clock { now(): ISODateTime; today(tz: TimeZone): ISODate; }
export interface IdGenerator { next(): string; }   // UUID v7
```

La clave es genérica por una razón concreta: `DailyEntry` no tiene identificador propio — su identidad es el par (atleta, día local), igual que en el esquema de almacenamiento (§7.2). Forzarle un `id` artificial permitiría dos entradas para el mismo día, que es justo el estado que el modelo no debe poder representar.

Todas las firmas son asíncronas **desde el principio**, aunque localStorage sea síncrono. Cambiar `T` por `Promise<T>` después obliga a tocar cada componente que consume datos; hacerlo desde el día uno cuesta cero.

---

# 3. Los siete módulos

| # | Módulo | Entra | Sale | Capa dominante |
|---|---|---|---|---|
| 1 | **Assessment Lab** | Protocolos y resultados crudos | `Assessment` validado, normalizado y con percentil | Domain + Application |
| 2 | **Archetype Designer** | Deporte, posición, nivel, fuentes | `Archetype` → `TargetProfile` | Domain |
| 3 | **Decision Engine** | `AthleteModel` + `TargetProfile` + métricas | `Gap[]`, `Diagnosis[]`, `Decision[]` | Decision |
| 4 | **Program Generator** | `Decision[]` + disponibilidad + restricciones | `TrainingPlan` | Domain + Decision |
| 5 | **Daily Tracker** | Check-in, sesión ejecutada, sRPE | `DailyEntry` | Application |
| 6 | **Analytics Center** | `DailyEntry[]`, `Assessment[]` | `KPI[]`, series, tendencias | Analytics |
| 7 | **Digital Athlete** | Todo lo anterior | `AthleteModel` versionado | Domain |

## 3.1 Assessment Lab

Ejecuta protocolos de evaluación y convierte números crudos en datos comparables. Su valor no está en guardar un salto de 38 cm, sino en saber que ese 38 es percentil 62 para un medio-scrum de 24 años y que se midió con plataforma de contacto y no con app de móvil (que sobreestima ~8 %).

Responsabilidades: catálogo de protocolos con sus condiciones; validación de rango plausible (un CMJ de 95 cm es un error de tipeo, no un récord); normalización a z-score contra la norma correspondiente; cálculo de asimetrías (LSI) en tests bilaterales; y **fecha de caducidad** — un test de fuerza de hace ocho meses no describe al atleta de hoy, y el sistema lo marca como vencido en lugar de usarlo en silencio.

## 3.2 Archetype Designer

Define el "atleta ideal" contra el que se compara. Un `Archetype` es una plantilla reutilizable (*Segunda línea de rugby, senior, nivel provincial*); un `TargetProfile` es esa plantilla instanciada para un atleta concreto y un horizonte temporal, con los objetivos ajustados a su punto de partida.

La distinción importa: comparar a un juvenil de 17 años contra el arquetipo de un profesional produce brechas enormes en todo y prioridades inútiles. El `TargetProfile` interpola entre el estado actual y el arquetipo según el horizonte, y esa interpolación es la que genera objetivos alcanzables.

## 3.3 Decision Engine

El activo principal del producto. Detalle completo en §6.

## 3.4 Program Generator

Traduce prioridades en un plan concreto. Consume las `Decision` del motor —qué cualidades priorizar, con qué intervenciones, bajo qué restricciones— y resuelve el problema de asignación: qué sesión, qué día, qué ejercicios, qué series y cargas. La periodización, las plantillas de mesociclo y los guardarraíles de la Especificación v2 viven acá, ya reescritos en TypeScript en el prototipo actual.

## 3.5 Daily Tracker

El módulo que decide si el producto sirve o no, porque sin datos diarios todo lo demás es adorno. Requisito de diseño no negociable: **el check-in completo se responde en menos de 20 segundos y con una sola mano**. Cada campo adicional que alguien quiera agregar tiene que justificar su costo en adherencia.

Captura: check-in matutino (sueño, fatiga, dolor con mapa corporal, estrés, ánimo, VHR opcional), sesión ejecutada (duración, sRPE, series reales) y eventos (dolor, enfermedad, viaje).

## 3.6 Analytics Center

Calcula, no decide. Todas las métricas de §7 de la Especificación v2, más las series que alimentan los gráficos y la detección de tendencias (pendiente sobre ventana móvil, con su intervalo de confianza). Es la capa donde más fácil se cuelan errores silenciosos, así que es la que más tests de valores conocidos lleva.

## 3.7 Digital Athlete

El `AthleteModel`: la representación viva del atleta, reconstruida a partir de todo lo anterior. No es una tabla de perfil — es un objeto derivado que incluye capacidades actuales con su antigüedad y confianza, estado de carga, historial de lesiones, restricciones activas y constantes personales calibradas.

Se recalcula, no se edita. Cualquier campo que un usuario pueda escribir a mano pertenece a otra entidad; el `AthleteModel` es siempre el resultado de una función `buildAthleteModel(assessments, entries, injuries, calibration, clock)`.

---

# 4. Tipos TypeScript

Convenciones: `strict: true` sin excepciones; identificadores tipados por marca para que no se pueda pasar un `AssessmentId` donde va un `AthleteId`; uniones discriminadas en lugar de campos opcionales que "a veces están"; y unidades explícitas en el nombre del campo (`weightKg`, no `weight`).

```ts
/* ── Primitivas y marcas ───────────────────────────────────────── */
declare const brand: unique symbol;
type Brand<T, B> = T & { readonly [brand]: B };

export type AthleteId    = Brand<string, 'AthleteId'>;
export type AssessmentId = Brand<string, 'AssessmentId'>;
export type PlanId       = Brand<string, 'PlanId'>;
export type ArchetypeId  = Brand<string, 'ArchetypeId'>;
export type RuleId       = Brand<string, 'RuleId'>;
export type DecisionId   = Brand<string, 'DecisionId'>;

export type ISODate     = Brand<string, 'ISODate'>;      // 2026-08-20
export type ISODateTime = Brand<string, 'ISODateTime'>;  // 2026-08-20T09:15:00Z
export type TimeZone    = Brand<string, 'TimeZone'>;     // America/Argentina/Buenos_Aires

export type Sport = 'rugby' | 'football' | 'hockey' | 'running' | 'strength';
export type Sex = 'male' | 'female' | 'other' | 'undisclosed';
export type Level = 'beginner' | 'intermediate' | 'advanced' | 'elite';

/** Las nueve cualidades físicas que el sistema modela y compara. */
export type Capacity =
  | 'maxStrength' | 'power' | 'speed' | 'changeOfDirection'
  | 'aerobicCapacity' | 'anaerobicCapacity'
  | 'mobility' | 'stability' | 'bodyComposition';

/* ── Medición: todo valor observado lleva su procedencia ───────── */
export type MeasurementSource = 'lab' | 'field' | 'wearable' | 'selfReport' | 'estimated';

export interface Measurement {
  readonly value: number;
  readonly unit: string;
  readonly measuredAt: ISODateTime;
  readonly source: MeasurementSource;
  /** 0–1. Cae con la antigüedad y con la calidad del método. */
  readonly confidence: number;
}

/* ── 1. Assessment ─────────────────────────────────────────────── */
export interface TestProtocol {
  readonly code: string;                 // 'cmj' | 'sprint_10m' | 'yoyo_ir1'
  readonly name: string;
  readonly capacity: Capacity;
  readonly unit: string;
  readonly higherIsBetter: boolean;
  readonly plausibleRange: readonly [number, number];
  readonly validityDays: number;         // tras esto, el resultado vence
  readonly bilateral: boolean;
}

export interface TestResult {
  readonly protocolCode: string;
  readonly raw: Measurement;
  readonly side?: 'left' | 'right' | 'bilateral';
  readonly zScore?: number;              // contra la norma aplicable
  readonly percentile?: number;
  readonly asymmetryPct?: number;        // solo en tests bilaterales
}

export interface Assessment {
  readonly id: AssessmentId;
  readonly athleteId: AthleteId;
  readonly performedOn: ISODate;
  readonly batteryCode: string;
  readonly results: readonly TestResult[];
  readonly conditions: {
    readonly fatigueBefore?: 1 | 2 | 3 | 4 | 5;
    readonly hoursSinceLastSession?: number;
    readonly surface?: string;
    readonly temperatureC?: number;
  };
  readonly notes?: string;
  readonly createdAt: ISODateTime;
}

/* ── 2. Archetype y TargetProfile ──────────────────────────────── */
export interface CapacityTarget {
  readonly capacity: Capacity;
  readonly targetZ: number;              // objetivo en z contra la norma
  readonly weight: number;               // 0–1, importancia para el deporte
  readonly minimumZ?: number;            // umbral por debajo del cual es un riesgo
}

export type EvidenceGrade = 'published' | 'internalData' | 'expertEstimate';

export interface Archetype {
  readonly id: ArchetypeId;
  readonly name: string;
  readonly sport: Sport;
  readonly position?: string;
  readonly level: Level;
  readonly sex: Sex;
  readonly ageRange: readonly [number, number];
  readonly targets: readonly CapacityTarget[];
  readonly evidence: {
    readonly grade: EvidenceGrade;
    readonly reference?: string;
    readonly sampleSize?: number;
  };
  readonly version: string;
}

export interface TargetProfile {
  readonly athleteId: AthleteId;
  readonly archetypeId: ArchetypeId;
  readonly horizonWeeks: number;
  readonly createdOn: ISODate;
  /** Interpolado entre el estado actual y el arquetipo según el horizonte. */
  readonly targets: readonly CapacityTarget[];
}

/* ── 3. AthleteModel (Digital Athlete) ─────────────────────────── */
export interface CapacityState {
  readonly capacity: Capacity;
  readonly currentZ: number | null;
  readonly measuredAt: ISODateTime | null;
  readonly ageDays: number | null;
  readonly isStale: boolean;
  readonly trend: 'improving' | 'stable' | 'declining' | 'unknown';
  readonly confidence: number;
}

export interface LoadState {
  readonly acute7d: number;
  readonly chronic28d: number;
  readonly acwrEwma: number | null;
  readonly monotony: number | null;
  readonly strain: number | null;
  readonly fitness: number;
  readonly fatigue: number;
  readonly form: number;
  readonly daysOfData: number;
}

export interface Restriction {
  readonly kind: string;                 // 'noAxialLoad' | 'noSprint' | 'maxRpe6'
  readonly bodyRegion?: string;
  readonly validFrom: ISODate;
  readonly validTo?: ISODate;
  readonly issuedBy: string;
  readonly requiresClearance: boolean;
}

export interface InjuryRecord {
  readonly bodyRegion: string;
  readonly side?: 'left' | 'right';
  readonly occurredOn: ISODate;
  readonly clearedOn?: ISODate;
  readonly severityDays?: number;
  readonly isRecurrence: boolean;
}

/** Constantes ajustadas al individuo: NO son un modelo entrenado. */
export interface PersonalCalibration {
  readonly fitnessTau: number;           // por defecto 42
  readonly fatigueTau: number;           // por defecto 7
  readonly hrvBaseline: number | null;
  readonly hrvSd: number | null;
  readonly sleepNeedHours: number;
  readonly calibratedAt: ISODateTime | null;
  readonly sampleDays: number;
  readonly isCalibrated: boolean;        // false hasta ≥ 84 días de datos
}

export interface AthleteModel {
  readonly id: AthleteId;
  readonly profile: {
    readonly birthDate: ISODate;
    readonly sex: Sex;
    readonly sport: Sport;
    readonly position?: string;
    readonly level: Level;
    readonly timezone: TimeZone;
    readonly heightCm?: number;
    readonly weightKg?: number;
  };
  readonly capacities: readonly CapacityState[];
  readonly load: LoadState;
  readonly readiness: ReadinessSnapshot | null;
  readonly injuries: readonly InjuryRecord[];
  readonly restrictions: readonly Restriction[];
  readonly calibration: PersonalCalibration;
  readonly builtAt: ISODateTime;
  readonly dataCompletenessPct: number;
}

/* ── 4. DailyEntry ─────────────────────────────────────────────── */
export interface WellnessCheckIn {
  readonly sleepHours: number;
  readonly sleepQuality: 1 | 2 | 3 | 4 | 5;
  readonly fatigue: 1 | 2 | 3 | 4 | 5;
  readonly soreness: 1 | 2 | 3 | 4 | 5;
  readonly stress: 1 | 2 | 3 | 4 | 5;
  readonly mood: 1 | 2 | 3 | 4 | 5;
  readonly sorenessMap?: Readonly<Record<string, 1 | 2 | 3 | 4 | 5>>;
  readonly lnRmssd?: number;
  readonly restingHr?: number;
}

export interface SetLog {
  readonly exerciseCode: string;
  readonly setNumber: number;
  readonly reps?: number;
  readonly loadKg?: number;
  readonly rir?: number;
  readonly meanVelocityMs?: number;
  readonly distanceM?: number;
  readonly durationS?: number;
}

export interface SessionLog {
  readonly plannedSessionId?: string;
  readonly startedAt: ISODateTime;
  readonly durationMin: number;
  readonly sessionRpe: number;           // CR-10
  readonly internalLoadAu: number;       // durationMin × sessionRpe
  readonly completionPct: number;
  readonly sets: readonly SetLog[];
  readonly painReported: boolean;
  readonly painDetail?: { readonly region: string; readonly nrs: number };
}

export interface DailyEntry {
  readonly athleteId: AthleteId;
  readonly date: ISODate;                // día local del atleta
  readonly checkIn?: WellnessCheckIn;
  readonly sessions: readonly SessionLog[];
  readonly totalLoadAu: number;
  readonly notes?: string;
  readonly updatedAt: ISODateTime;
}

export interface ReadinessComponent {
  readonly key: 'hrv' | 'sleep' | 'fatigue' | 'soreness' | 'mood' | 'loadState' | 'restingHr';
  readonly weight: number;
  readonly normalized: number | null;    // 0–1, null si falta el dato
  readonly evidence?: string;
}

export interface ReadinessSnapshot {
  readonly date: ISODate;
  readonly score: number | null;         // 0–100
  readonly band: 'green' | 'greenSoft' | 'amber' | 'amberLow' | 'red' | 'insufficientData';
  readonly components: readonly ReadinessComponent[];
  readonly completenessPct: number;
}

/* ── 5. KPI ────────────────────────────────────────────────────── */
export interface KPI {
  readonly key: string;
  readonly label: string;
  readonly value: number | null;
  readonly unit: string;
  readonly target?: number;
  readonly band?: 'good' | 'watch' | 'critical';
  readonly trend?: { readonly slope: number; readonly windowDays: number; readonly isSignificant: boolean };
  readonly computedAt: ISODateTime;
}

/* ── 6. Gap y Diagnosis ────────────────────────────────────────── */
export interface Gap {
  readonly capacity: Capacity;
  readonly currentZ: number | null;
  readonly targetZ: number;
  readonly deltaZ: number | null;        // target − current
  readonly weightedDelta: number | null; // deltaZ × peso del arquetipo
  readonly isBlocking: boolean;          // por debajo del mínimo del arquetipo
  readonly confidence: number;
}

export type DiagnosisSeverity = 'info' | 'watch' | 'action' | 'critical';

export interface Diagnosis {
  readonly code: string;                 // 'STRENGTH_DEFICIT' | 'LOAD_SPIKE' | 'HRV_SUPPRESSED'
  readonly title: string;
  readonly severity: DiagnosisSeverity;
  readonly capacity?: Capacity;
  readonly evidence: readonly string[];  // frases con métrica, valor y umbral
  readonly firedRules: readonly RuleId[];
  readonly detectedOn: ISODate;
}

/* ── 7. DecisionRule y Decision ────────────────────────────────── */
export type Comparator = 'lt' | 'lte' | 'gt' | 'gte' | 'eq' | 'between' | 'exists' | 'missing';

export interface Condition {
  readonly path: string;                 // 'load.acwrEwma' | 'readiness.score'
  readonly op: Comparator;
  readonly value?: number | string | readonly [number, number];
}

export type ActionSpec =
  | { readonly type: 'reduceVolume'; readonly factor: number; readonly keepIntensity: boolean }
  | { readonly type: 'substituteSession'; readonly withQuality: string }
  | { readonly type: 'prioritizeCapacity'; readonly capacity: Capacity; readonly weight: number }
  | { readonly type: 'addIntervention'; readonly interventionCode: string }
  | { readonly type: 'capLoad'; readonly maxWeeklyAu: number }
  | { readonly type: 'blockProgression'; readonly capacity: Capacity }
  | { readonly type: 'requireHumanReview'; readonly reason: string }
  | { readonly type: 'raiseDiagnosis'; readonly code: string; readonly severity: DiagnosisSeverity };

export interface DecisionRule {
  readonly id: RuleId;
  readonly name: string;
  readonly description: string;
  /** Menor número = se evalúa antes y gana los conflictos. */
  readonly priority: number;
  /** Las reglas de seguridad no se pueden desactivar ni sobrescribir. */
  readonly isGuardrail: boolean;
  readonly when: { readonly all?: readonly Condition[]; readonly any?: readonly Condition[] };
  readonly then: readonly ActionSpec[];
  readonly rationaleTemplate: string;    // 'Bajamos el volumen porque tu ACWR es {load.acwrEwma}'
  readonly reference?: string;           // cita científica que la respalda
  readonly enabled: boolean;
}

export interface DecisionRecord {
  readonly id: DecisionId;
  readonly athleteId: AthleteId;
  readonly date: ISODate;
  readonly kind: 'planGeneration' | 'dailyAdjustment' | 'deload' | 'sessionSwap'
              | 'prioritySet' | 'guardrailBlock' | 'manualOverride';
  readonly subject: { readonly type: string; readonly id: string };
  readonly inputsSnapshot: Readonly<Record<string, unknown>>;
  readonly firedRules: readonly { readonly ruleId: RuleId; readonly evidence: string }[];
  readonly actions: readonly ActionSpec[];
  readonly rationaleEs: string;
  readonly engineVersion: string;
  readonly rulesetVersion: string;
  readonly requiresReview: boolean;
  readonly review?: {
    readonly outcome: 'accepted' | 'overridden' | 'rejected';
    readonly by: string;
    readonly at: ISODateTime;
    readonly reason?: string;
  };
  readonly createdAt: ISODateTime;
}

/* ── 8. TrainingPlan ───────────────────────────────────────────── */
export type MesocycleFocus = 'accumulation' | 'transmutation' | 'realization' | 'taper' | 'transition' | 'rehab';
export type IntensityType = 'pct1rm' | 'rpe' | 'rir' | 'velocity' | 'pctHrMax' | 'pace' | 'absolute';

export interface PrescribedItem {
  readonly exerciseCode: string;
  readonly sets: number;
  readonly repsMin?: number;
  readonly repsMax?: number;
  readonly intensityType: IntensityType;
  readonly intensityValue?: number;
  readonly loadKg?: number;
  readonly restSeconds?: number;
  readonly durationSeconds?: number;
  readonly distanceM?: number;
  readonly tempo?: string;
  readonly notes?: string;
}

export interface SessionBlock {
  readonly kind: 'warmup' | 'main' | 'accessory' | 'conditioning' | 'prehab' | 'cooldown';
  readonly structure: 'straight' | 'superset' | 'circuit' | 'interval';
  readonly items: readonly PrescribedItem[];
}

export interface PlannedSession {
  readonly id: string;
  readonly date: ISODate;
  readonly version: number;
  readonly sessionType: string;
  readonly primaryCapacity: Capacity;
  readonly plannedDurationMin: number;
  readonly targetRpe: number;
  readonly plannedLoadAu: number;
  readonly blocks: readonly SessionBlock[];
  readonly status: 'planned' | 'modified' | 'completed' | 'partial' | 'skipped';
  readonly adjustedBy?: DecisionId;
}

export interface Microcycle {
  readonly ordinal: number;
  readonly startsOn: ISODate;
  readonly pattern: 'loading' | 'unloading' | 'competition' | 'recovery';
  readonly plannedLoadAu: number;
  readonly sessions: readonly PlannedSession[];
}

export interface Mesocycle {
  readonly ordinal: number;
  readonly name: string;
  readonly focus: MesocycleFocus;
  readonly startsOn: ISODate;
  readonly endsOn: ISODate;
  readonly targetCapacities: readonly Capacity[];
  readonly microcycles: readonly Microcycle[];
}

export interface TrainingPlan {
  readonly id: PlanId;
  readonly athleteId: AthleteId;
  readonly targetProfileId: string;
  readonly startsOn: ISODate;
  readonly endsOn: ISODate;
  readonly status: 'draft' | 'active' | 'paused' | 'completed' | 'archived';
  readonly mesocycles: readonly Mesocycle[];
  readonly generatorVersion: string;
  readonly rulesetVersion: string;
  readonly generatedBy: DecisionId;
  readonly guardrailReport: readonly GuardrailCheck[];
}

export interface GuardrailCheck {
  readonly ruleId: RuleId;
  readonly label: string;
  readonly limit: string;
  readonly observed: string;
  readonly passed: boolean;
}
```

---

# 5. Modelos del dominio

## 5.1 Invariantes que el código garantiza

Estas no son recomendaciones: son condiciones que el constructor de cada entidad valida y que los tests de propiedades verifican con entradas aleatorias.

1. Un `Assessment` no se guarda con un valor fuera de `plausibleRange`; se rechaza y se pide confirmación explícita.
2. Un `TestResult` sin norma aplicable tiene `zScore` y `percentile` en `undefined`, nunca en `0`.
3. `DailyEntry.totalLoadAu` siempre es la suma de `sessions[].internalLoadAu`. Es un campo derivado y se recalcula al guardar.
4. Una `PlannedSession` no se modifica en sitio: se incrementa `version` y se registra la `DecisionId` que la cambió.
5. Ninguna prescripción con `intensityType: 'pct1rm'` se emite sin un 1RM vigente; sin él, se degrada a `rir`.
6. Un `AthleteModel` con `dataCompletenessPct < 50` no produce `readiness`, y el motor lo trata como dato ausente en lugar de asumir normalidad.
7. Toda `Decision` con `requiresReview: true` bloquea la publicación del plan hasta que exista `review`.

## 5.2 Value objects y unidades

El error más caro y más frecuente en este dominio es mezclar unidades: kilos con libras, metros por segundo con kilómetros por hora, minutos con segundos. La defensa es que la unidad viva en el nombre del campo (`loadKg`, `distanceM`, `durationS`) y que las conversiones existan en un solo módulo, `domain/units.ts`, con tests exhaustivos. No se aceptan campos llamados `value` sueltos fuera de `Measurement`, que lleva su `unit` al lado.

## 5.3 Procedencia y confianza

Cada dato del sistema arrastra dos metadatos que la UI muestra y el motor usa: **de dónde salió** (`MeasurementSource`) y **cuánto vale hoy** (`confidence`). La confianza decae con la antigüedad, con una constante por cualidad — la fuerza máxima se pierde despacio, la potencia y la condición aeróbica más rápido:

```ts
export function confidenceOf(m: Measurement, capacity: Capacity, now: ISODateTime): number {
  const halfLife = HALF_LIFE_DAYS[capacity];         // p. ej. fuerza 120 d, aeróbico 45 d
  const ageDays = daysBetween(m.measuredAt, now);
  const sourceFactor = SOURCE_FACTOR[m.source];      // lab 1.0, campo 0.9, autoinforme 0.6
  return clamp01(sourceFactor * Math.pow(0.5, ageDays / halfLife));
}
```

Esto es lo que permite que el sistema diga "tu potencia parece baja, pero el dato tiene siete meses: medila antes de que armemos el bloque" en lugar de prescribir sobre información vencida.

---

# 6. Motor de decisión

## 6.1 Las reglas son datos, no código

Una regla escrita en TypeScript hay que desplegarla para cambiarla, no se puede versionar por separado y no se puede auditar sin leer el código. Una regla escrita como dato (`DecisionRule`) se guarda, se versiona, se muestra en pantalla y se le puede pedir a un preparador físico que la revise sin que sepa programar.

```json
{
  "id": "GR_WEEKLY_INCREASE",
  "name": "Techo de incremento de carga semanal",
  "priority": 10,
  "isGuardrail": true,
  "when": { "all": [{ "path": "plan.weeklyIncreasePct", "op": "gt", "value": 0.15 }] },
  "then": [
    { "type": "capLoad", "maxWeeklyAu": 0 },
    { "type": "requireHumanReview", "reason": "Incremento semanal sobre el límite" }
  ],
  "rationaleTemplate": "El plan sube la carga un {plan.weeklyIncreasePct|pct} respecto de las últimas 3 semanas; el techo es 15 %.",
  "reference": "Gabbett 2016; Soligard et al. 2016",
  "enabled": true
}
```

## 6.2 El pipeline

```ts
export function decide(ctx: DecisionContext): DecisionOutcome {
  const gaps        = computeGaps(ctx.model, ctx.target);          // 1
  const facts       = flattenFacts(ctx.model, ctx.metrics, gaps);  // 2
  const fired       = evaluateRules(ctx.ruleset, facts);           // 3
  const guardrails  = fired.filter(r => r.rule.isGuardrail);       // 4
  const diagnoses   = buildDiagnoses(fired, gaps, ctx.clock);      // 5
  const priorities  = rankPriorities(gaps, diagnoses, ctx.target); // 6
  const actions     = resolveConflicts(fired);                     // 7
  return { gaps, diagnoses, priorities, actions, guardrails,
           trace: buildTrace(ctx, fired, actions) };               // 8
}
```

**1. Brechas.** `deltaZ = targetZ − currentZ`, ponderado por la importancia de la cualidad en el arquetipo. Una brecha sin dato actual no es cero: es `null`, y genera una acción distinta — *medir*, no *entrenar*.

**2. Hechos.** El modelo se aplana a un diccionario de rutas (`load.acwrEwma`, `readiness.score`, `gaps.maxStrength.deltaZ`) para que las condiciones de las reglas sean datos. El aplanado es la única parte reflexiva del motor y está cubierta por tests de contrato contra los tipos.

**3. Evaluación.** Todas las reglas habilitadas se evalúan; no hay cortocircuito. Una regla que no dispara también se registra en la traza con el valor observado, porque saber que el ACWR estaba en 1,21 y no disparó es tan informativo como el disparo.

**4. Guardarraíles primero.** Si un guardarraíl dispara, su acción no puede ser anulada por ninguna regla de prioridad menor. Es la única asimetría dura del motor.

**5. Diagnósticos.** Agrupan reglas disparadas en afirmaciones legibles con su evidencia. Un diagnóstico sin evidencia citable es un bug.

**6. Prioridades.** Se ordenan las brechas por `weightedDelta`, penalizando las de baja confianza y elevando las que son `isBlocking`. Se limita a **tres prioridades activas**: un plan que persigue nueve cualidades no persigue ninguna.

**7. Conflictos.** Dos reglas pueden pedir cosas opuestas (subir volumen por brecha de resistencia, bajarlo por ACWR alto). Resolución: gana la de menor `priority`; entre acciones del mismo tipo se toma la más conservadora (el menor `factor`, el menor `maxWeeklyAu`); las acciones de tipos distintos se acumulan si no se contradicen.

**8. Traza.** Un `DecisionRecord` con el snapshot completo de entradas, las reglas disparadas y las no disparadas con su valor observado, la versión del ruleset y del motor. Con eso, cualquier decisión de hace seis meses se reproduce exactamente.

## 6.3 Determinismo

El motor es una función pura. Mismo `DecisionContext`, misma salida, siempre. Nada de `Date.now()`, `Math.random()` ni lecturas de almacenamiento adentro. El reloj entra como `ctx.clock`, y los tests le pasan un reloj fijo.

Esto habilita la prueba más valiosa del sistema: **replay**. Se toma el historial real de un atleta, se reproducen las decisiones día a día con el ruleset nuevo y se compara contra lo que decidió el ruleset viejo. Cualquier cambio de reglas se evalúa así antes de publicarse.

## 6.4 Explicabilidad

`rationaleTemplate` se interpola con los valores reales y produce la frase que ve el atleta. La plantilla vive junto a la regla, así que es imposible cambiar el umbral sin ver el texto que lo explica. Regla de redacción: **métrica, valor, umbral y acción**, en segunda persona y sin jerga.

> "Tu VHR lleva dos días por debajo de tu rango normal (3,98 contra un piso de 4,02) y dormiste 6,0 h de media. Bajamos el volumen un 25 % y mantenemos la intensidad."

## 6.5 Dónde entra el LLM, y dónde no

El brief menciona sistema experto; la Especificación v2 preveía un orquestador de IA. La frontera se mantiene: **el LLM no prescribe**. Puede leer el contexto, explicar una decisión ya tomada, traducir lenguaje natural a intención estructurada y proponer un ajuste — que el motor determinista valida contra los guardarraíles antes de aplicarlo. En el MVP el LLM no está: el motor de reglas se vale por sí solo, y agregarlo después no cambia esta arquitectura.

## 6.6 "Aprender con el tiempo", con precisión

Lo que el sistema hace sobre un atleta es **calibración**, no aprendizaje:

| Constante | Cómo se ajusta | Datos mínimos |
|---|---|---|
| `fitnessTau`, `fatigueTau` | Minimizar error contra resultados de tests | 84 días con ≥ 60 % de adherencia |
| `hrvBaseline`, `hrvSd` | Media y DE móviles sobre `ln rMSSD` | 30 días |
| `sleepNeedHours` | Sueño con el que el readiness es máximo | 60 días |
| Umbrales personales de ACWR | Distribución individual de carga | 12 semanas |

Hasta alcanzar el mínimo, se usan los valores por defecto y `isCalibrated: false`, y la UI lo dice. El aprendizaje entre atletas —modelos entrenados con población— queda explícitamente fuera del MVP y requiere Supabase, volumen y consentimiento.

---

# 7. Estructura de carpetas y persistencia

## 7.1 Árbol

```
src/
├── domain/                     # cero dependencias externas
│   ├── types/                  # los tipos del §4, uno por agregado
│   ├── athlete/                # buildAthleteModel, capacidades, confianza
│   ├── assessment/             # protocolos, normalización, percentiles
│   ├── archetype/              # arquetipos, interpolación a TargetProfile
│   ├── plan/                   # periodización, plantillas, prescripción
│   ├── exercise/               # catálogo, sustituciones, contraindicaciones
│   ├── units.ts                # única fuente de conversiones
│   └── invariants.ts           # constructores validados
├── analytics/
│   ├── load.ts                 # sRPE, TRIMP, volume load
│   ├── acwr.ts                 # media móvil y EWMA
│   ├── foster.ts               # monotonía y strain
│   ├── banister.ts             # fitness-fatiga
│   ├── hrv.ts                  # línea base y SWC
│   ├── readiness.ts            # índice compuesto
│   └── series.ts               # ventanas, tendencias, z-scores
├── decision/
│   ├── engine.ts               # el pipeline de §6.2
│   ├── facts.ts                # aplanado del modelo a rutas
│   ├── evaluator.ts            # condiciones y comparadores
│   ├── conflicts.ts            # resolución
│   ├── guardrails.ts           # reglas duras, no desactivables
│   ├── rationale.ts            # interpolación de plantillas
│   └── rulesets/
│       ├── ais-2026.08.json    # ruleset versionado
│       └── schema.ts           # validación Zod del ruleset
├── application/
│   ├── ports/                  # Repository, UnitOfWork, Clock, IdGenerator
│   ├── usecases/               # runAssessment, generateProgram, logDay…
│   ├── stores/                 # Zustand: athlete, plan, tracker, ui
│   └── services/               # composición de casos de uso
├── infrastructure/
│   ├── storage/
│   │   ├── localStorage.ts     # adaptador
│   │   ├── keys.ts             # espacio de nombres y versión
│   │   ├── migrations/         # v1→v2, v2→v3…
│   │   └── quota.ts            # medición y política de purga
│   ├── supabase/               # adaptador futuro, misma interfaz
│   └── import/                 # CSV, Apple Health, Garmin
├── ui/
│   ├── modules/                # una carpeta por módulo del §3
│   │   ├── assessment-lab/
│   │   ├── archetype-designer/
│   │   ├── decision-engine/
│   │   ├── program-generator/
│   │   ├── daily-tracker/
│   │   ├── analytics-center/
│   │   └── digital-athlete/
│   ├── components/             # design system: Card, Metric, Band, Chart
│   ├── hooks/
│   ├── theme/                  # tokens; claro y oscuro
│   └── routes.tsx
└── main.tsx

tests/
├── domain/                     # unitarias
├── analytics/                  # valores conocidos, comparados a mano
├── decision/
│   ├── rules.spec.ts
│   ├── properties.spec.ts      # invariantes con fast-check
│   └── replay/                 # historiales sintéticos y su salida esperada
└── e2e/
```

**Por qué `ui/modules/` y no `ui/pages/`:** los siete módulos del brief son unidades de producto con estado y lógica de presentación propias. Cada carpeta contiene sus componentes, sus hooks y sus tipos de vista, y solo exporta su ruta. Un módulo no importa componentes internos de otro; comparte a través de `ui/components`.

## 7.2 Esquema de localStorage

Namespace único, versión en la clave, un registro por agregado más índices. Nada de un blob gigante: escribir 3 MB en cada check-in agota el presupuesto de escritura y bloquea el hilo principal.

```
ais:v1:meta                        → { schemaVersion, createdAt, lastMigrationAt }
ais:v1:athlete:current             → AthleteId activo
ais:v1:athlete:{id}:profile        → perfil editable
ais:v1:athlete:{id}:model          → AthleteModel derivado (caché, regenerable)
ais:v1:athlete:{id}:calibration    → PersonalCalibration
ais:v1:assessment:{id}             → Assessment
ais:v1:entry:{athleteId}:{date}    → DailyEntry            (clave por día: escritura mínima)
ais:v1:plan:{id}                   → TrainingPlan
ais:v1:decision:{id}               → DecisionRecord
ais:v1:archetype:{id}              → Archetype
ais:v1:ruleset:active              → versión del ruleset en uso
ais:v1:index:assessments:{athlete} → [{ id, performedOn, batteryCode }]
ais:v1:index:entries:{athlete}     → ['2026-08-18', '2026-08-19', …]
ais:v1:index:decisions:{athlete}   → [{ id, date, kind }]
```

Reglas de la capa de almacenamiento:

- **Los índices son la única forma de listar.** Nunca se itera `Object.keys(localStorage)` en tiempo de render.
- **`model` es caché.** Se puede borrar entero y reconstruir desde `assessment` + `entry`. Si alguna vez no se puede, es que hay estado que solo vive ahí, y eso es un bug.
- **Escritura por agregado.** Un check-in escribe una clave (`entry:{athlete}:{date}`) y actualiza un índice. Nunca reescribe el historial.
- **Serialización explícita.** `toJSON` / `fromJSON` por entidad, con validación Zod al leer. Un dato corrupto o de una versión vieja se detecta al entrar, no tres pantallas después.
- **Presupuesto.** ~5 MB por origen. Un año de uso intensivo: ~365 `DailyEntry` (~1,5 KB), ~50 `Assessment`, ~500 `DecisionRecord` (~2 KB) ≈ 1,8 MB. Entra, pero con `DecisionRecord` guardando snapshots completos el margen se acorta: se aplica retención de 180 días para las decisiones rutinarias, conservando siempre las de `guardrailBlock` y `manualOverride`.

## 7.3 Migraciones

```ts
// infrastructure/storage/migrations/index.ts
export const migrations: readonly Migration[] = [
  { from: 1, to: 2, describe: 'sorenessMap en el check-in', run: m1to2 },
  { from: 2, to: 3, describe: 'confidence en Measurement', run: m2to3 }
];

export async function migrate(store: KeyValueStore): Promise<MigrationReport> {
  const meta = await store.get('ais:v1:meta');
  let version = meta?.schemaVersion ?? 1;
  const backup = await snapshot(store);          // copia completa antes de tocar nada
  try {
    for (const m of migrations.filter(m => m.from >= version)) {
      await m.run(store);
      version = m.to;
      await store.set('ais:v1:meta', { ...meta, schemaVersion: version, lastMigrationAt: nowIso() });
    }
    return { ok: true, version };
  } catch (e) {
    await restore(store, backup);                // vuelta atrás completa
    return { ok: false, version, error: String(e) };
  }
}
```

Las migraciones corren una sola vez, al arranque, antes de montar la app, y con copia de seguridad previa. Una migración a medias es peor que no migrar.

## 7.4 Camino a Supabase

Como la app habla con `UnitOfWork` y no con `localStorage`, el cambio es un adaptador nuevo y una línea en el arranque:

```ts
const uow = import.meta.env.VITE_BACKEND === 'supabase'
  ? createSupabaseUnitOfWork(supabaseClient)
  : createLocalUnitOfWork(window.localStorage);
```

El mapeo de claves a tablas ya está resuelto: cada `ais:v1:{entidad}:{id}` es una fila de la tabla homónima del esquema PostgreSQL de la Especificación v2, que ya está escrito y validado. Se añade `athlete_id` como columna de aislamiento y las políticas RLS de §4.15 de aquel documento.

**El paso delicado es el primero, no el segundo:** la migración de datos locales a la nube. Requiere resolución de conflictos (misma fecha, dos dispositivos), y la política tiene que decidirse antes de escribir el adaptador. Propuesta: *last-write-wins* por agregado, con la excepción de `DailyEntry`, donde se fusiona a nivel de campo y se conserva la sesión con más detalle.

---

# 8. Riesgos técnicos

Ordenados por daño esperado, no por probabilidad.

| # | Riesgo | Por qué duele | Mitigación |
|---|---|---|---|
| 1 | **Pérdida de datos en localStorage** | El usuario borra caché, usa modo privado o cambia de teléfono y pierde meses. Es el fin del producto para esa persona | Exportación JSON con un toque, recordatorio automático cada 30 días, aviso claro de que los datos son locales, y Supabase priorizado en cuanto haya usuarios reales |
| 2 | **Datos de salud sin cifrar en el dispositivo** | VHR, lesiones y dolor son categoría especial (art. 9 RGPD). En localStorage quedan en claro para cualquier script del origen | Cero dependencias de terceros en runtime, CSP estricta, sin analítica que toque datos de salud. Cifrado en reposo con clave derivada de contraseña cuando llegue el multiusuario |
| 3 | **Adherencia baja al check-in** | Sin datos diarios, el motor no decide y el producto no vale nada | 20 segundos y una mano. Degradación explícita con pesos redistribuidos. Nunca imputar en silencio |
| 4 | **Errores silenciosos en analítica** | Un signo cambiado en el z-score produce recomendaciones invertidas que nadie detecta | Tests de valores conocidos calculados a mano, tests de propiedades e invariantes, y comparación contra el prototipo actual como implementación de referencia |
| 5 | **Arquetipos sin respaldo** | Brechas inventadas → prioridades inventadas → plan inútil, con apariencia de rigor | `EvidenceGrade` obligatorio y visible en la UI junto a cada brecha |
| 6 | **Zona horaria y "día de entrenamiento"** | Un check-in a las 23:50 en UTC−3 cae en el día siguiente en UTC. Corrompe ACWR y monotonía sin aviso | `ISODate` local del atleta como clave del día; UTC solo para instantes. Tests con viajes entre husos |
| 7 | **Deriva entre reglas y realidad** | Un ruleset que nadie revisa envejece y decide mal | Ruleset versionado con changelog, revisión del consejo deportivo antes de publicar, y replay obligatorio contra historiales reales |
| 8 | **Sobreconfianza del usuario en los números** | Presentar un score como verdad lleva a decisiones peores que no tener score | Bandas, no probabilidades. Evidencia junto a cada bandera. Nunca "riesgo de lesión: 34 %" |
| 9 | **Migraciones de esquema** | Una migración a medias deja datos irrecuperables | Copia previa, transacción con vuelta atrás, validación Zod al leer |
| 10 | **Cálculo en el hilo principal** | Reconstruir el modelo con 2 años de historial congela la interfaz | Cálculo incremental por día, memoización por fecha, y Web Worker si el perfilado lo pide |
| 11 | **Acoplamiento de la UI a la lógica** | Un umbral en un componente se duplica y diverge | ESLint por capas (§2.1) y revisión: cualquier número mágico en `ui/` se rechaza |
| 12 | **Alcance del brief** | Siete módulos a la vez es un año sin release | Orden de §9, con un módulo utilizable por vez |

---

# 9. Orden de construcción

El brief pide avanzar módulo por módulo. Este es el orden, y no es arbitrario: cada paso deja algo usable y desbloquea al siguiente.

| Paso | Qué se construye | Por qué va acá | Terminado cuando |
|---|---|---|---|
| **0** | Esqueleto: Vite + React + TS + Tailwind, capas, ESLint de dependencias, Zod, Vitest, tipos del §4 | Sin las fronteras puestas desde el principio, se filtran en la semana dos | `pnpm test` y `pnpm lint` verdes en CI |
| **1** | **Daily Tracker** + almacenamiento + Analytics básica | Es lo único que genera datos. Todo lo demás se alimenta de acá | Un usuario registra 14 días y ve su carga, ACWR y monotonía |
| **2** | **Digital Athlete** | Con datos ya se puede construir el modelo | `buildAthleteModel` reconstruye el estado desde cero y es idempotente |
| **3** | **Assessment Lab** | Aporta las capacidades que el modelo aún no tiene | Batería completa con percentiles y detección de datos vencidos |
| **4** | **Archetype Designer** | Sin objetivo no hay brecha | Tres arquetipos de rugby con procedencia declarada |
| **5** | **Decision Engine** | Ya tiene modelo y objetivo: puede diagnosticar | Replay sobre historial sintético reproduce la salida esperada |
| **6** | **Program Generator** | Última pieza de la cadena | Plan de 4 semanas que respeta los guardarraíles |
| **7** | **Analytics Center** completo | Necesita historial acumulado para ser útil | Tendencias con intervalo de confianza y exportación |
| **8** | Supabase, multiusuario, wearables | Recién ahora hay algo que vale la pena sincronizar | Migración de datos locales sin pérdida, verificada |

Cada paso cierra con: tests verdes, la funcionalidad usable de punta a punta, y un `ADR` corto que registre lo que se decidió y lo que se descartó.

---

# 10. Qué reutilizar del trabajo ya hecho

No se arranca de cero. Ya existe y está probado:

| Activo | Dónde está | Cómo entra en AIS |
|---|---|---|
| Fórmulas de carga, ACWR, Foster, Banister, VHR, readiness | `prototipo/motor-decision.html` | Se extraen tal cual a `analytics/`; ya están en JavaScript y verificadas contra casos conocidos |
| Generador de microciclo, plantillas de mesociclo, prescripción | mismo archivo | Base de `domain/plan/` |
| Guardarraíles y bandas de ajuste | mismo archivo | Semilla del ruleset `ais-2026.08.json` |
| Esquema PostgreSQL completo y validado | `docs/especificacion-tecnica-v2.md` §4 | Destino del adaptador Supabase |
| Catálogo de tests, normas y ejercicios | §4.4 y §4.5 de la v2 | Datos iniciales de `domain/exercise/` y `domain/assessment/` |
| Formulación del readiness con pesos y redistribución | §7.7 de la v2 y el prototipo | `analytics/readiness.ts` |

El primer commit del repositorio nuevo debería ser justamente esa extracción: mover el motor del prototipo a `analytics/` y `domain/` con tests, antes de escribir una sola línea de React.
