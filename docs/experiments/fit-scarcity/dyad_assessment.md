# Model E: Dyad assessment (honest, not built)

## What Dyad is

Dyad is JuliaHub's declarative physical-modeling language, released in 2025
(formerly marketed under the JuliaSim umbrella). `.dyad` files describe
component-based, equation-oriented models — typed connectors, object-oriented
composition, a standard component library, GUI authoring, FMI export — and every
Dyad model **lowers to Julia code that uses ModelingToolkit.jl**, simulated by
the SciML stack (DifferentialEquations.jl, plus the Lux deep-learning stack for
neural components). It is positioned as a modern Modelica alternative: acausal
component modeling for *physical hardware systems* (thermal, hydraulic,
electrical, mechanical networks), with devops-grade packaging and CI.

Sources: [Dyad launch blog](https://juliahub.com/blog/dyad-making-hardware-as-easy-as-software),
[Dyad standard libraries](https://juliahub.com/blog/modeling-with-dyads-standard-libraries),
[ModelingToolkit.jl and Dyad manual page](https://help.juliahub.com/dyad/dev/manual/advanced/modelingtoolkit.html),
[Why Dyad? A Perspective for Modelica Users](https://juliahub.com/blog/why-dyad-a-perspective-for-modelica-users),
[Dyad (Formerly JuliaSim)](https://juliahub.com/blog/juliasim-redefining-model-based-engineering).

## Does it fit this task?

No — and we measured why before deciding. Dyad's sweet spot is a *continuous
dynamical system built from components with physical conservation laws at the
connections* (flows sum to zero, potentials equalize). The object of study here
is an **algebraic markup map** `y = f(margin, d̂, …)` evaluated hourly on a
day-ahead auction. Two facts from this experiment kill the ODE framing:

1. **The DA price has no intraday dynamics to model.** The auction clears all
   24 hours simultaneously; there is no causal hour-to-hour propagation. We
   tested this directly (`fit_dynamic.py`): a first-order relaxation
   `dP/dt = α(F(t) − P)` — exactly the kind of demand–supply relaxation ODE a
   Dyad price-formation component would encode — was fit jointly with the form
   constants, and **every zone drove α → 1.0**, collapsing the ODE to the
   static algebraic map. The apparent gains of lagged-price models
   (`D_gbt_full_dyn`) come from *conditioning on other hours of the same
   simultaneous clearing*, i.e. information leakage, not dynamics.
2. **What remains is regression, which is not Dyad's job.** Fitting free
   constants/functions inside a component model is exactly SciMLʼs
   universal-differential-equation workflow that Dyad wraps — but with no
   differential structure left, Dyad would only add ceremony around a
   four-parameter algebraic fit that `scipy.optimize.least_squares` solves in
   80 ms.

## What a Dyad price-formation model WOULD look like

If one insisted: a `PriceFormation` component with connector variables
(net-demand flow in, price potential out), internal states `P(t)` and a stored
`margin(t)` input, equations
`der(P) = α*(f(margin, d̂) * SRMC − P)` with `f` either the hinge form or a
neural component (Lux) for the UDE variant; a `ReservoirOpportunity` component
feeding a water-value term; composed per zone and coupled through an ATC
network component whose flows respect capacity limits. That last part —
multi-zone coupling as an acausal flow network — is the one place Dyad's
component semantics would genuinely shine, but it duplicates what
`src/mpcc/` already does with an actual optimizer, correctly (an LP's KKT
conditions, not a relaxation toward them).

**Verdict:** wrong tool for an algebraic markup fit; plausibly interesting for
a *future* continuous-time relaxation model of coupled zonal prices, but the
α → 1 measurement says the data does not ask for one. Effort spent here: web
research + this note (~well under the 20% budget), redirected into the
relaxation-ODE fit that answers the question quantitatively.
