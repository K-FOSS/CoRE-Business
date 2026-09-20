# K-FOSS/CoRE-Business Personal

This is a subset of CoRE-Business for my personal tools and apps until I get around to setting up a dedicated repo

The [Fitness](Fitness/README.md) stack is live at `gym.mylogin.space` under the
[Fitness ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Personal/Fitness.yaml).
It deploys to `core-fitness-prod` on `core-home1-talos-prod` through the Lovely
renderer.

The [History](History/README.md) stack deploys Dawarich at
`dawarich.mylogin.space` through the [Personal History ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Personal/History.yaml).
It uses the site-local Dragonfly service, Authentik OIDC and the production
cluster's PostgreSQL provider.
