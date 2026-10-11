# DarraOwl

Garde ton MacBook éveillé, capot fermé compris, pendant une durée limitée.
Chaque session a une heure de fin. À cette heure-là, la veille revient, même si
l'app a planté ou a été quittée.

État : phase 1 (le cœur côté Mac). L'app iPhone, la liaison et le mode capot
fermé arrivent dans les phases suivantes.

> Pose le Mac sur une surface stable et ventilée, jamais dans un sac fermé.

## Installation

Il faut macOS 26 ou plus récent sur un Mac Apple Silicon, ainsi que Xcode et
XcodeGen.

```bash
scripts/install-mac.sh
```

Le script refuse de continuer si Insomnia est encore installé. Il construit
l'app, la copie dans `/Applications` et l'ouvre. Il n'utilise jamais `sudo`.

## Premier lancement

1. Clique sur la chouette dans la barre des menus, puis sur **Installer le
   composant système**.
2. Réglages Système s'ouvre sur **Général > Ouverture**. Sous **Autoriser en
   arrière-plan**, active **DarraOwl**. macOS demande ton mot de passe ou
   Touch ID.
3. Reviens au menu : il propose maintenant les durées.

Le composant système est un petit service qui tourne en root. C'est le seul
à modifier les réglages d'alimentation. Il n'accepte que l'app DarraOwl
signée par le même développeur. Il tient le journal des changements et
rétablit la veille à l'heure de fin, au démarrage du Mac, et quand on le
désactive.

DarraOwl s'ajoute aussi à l'ouverture de session. Tu peux retirer ce réglage
dans DarraOwl > Réglages.

## Utilisation

- **Démarrer** : clique sur 30 min, 1 h, 2 h (Entrée) ou 4 h, ou tape une
  durée libre (`90`, `1h30`, `2:15`).
- **Prolonger** : clique sur +30 min ou +1 h pendant la session. La fin
  ne dépasse jamais la durée maximale (12 h par défaut, 24 h au plus).
- **Arrêter** : maintiens le bouton enfoncé 1,5 s.
- **Quitter** l'app arrête aussi la session.

Pendant une session, sur batterie :

- sous 40 %, le mode économie d'énergie s'active, puis se désactive au
  retour du chargeur ;
- sous 15 %, ou si la batterie devient illisible, la session s'arrête.

Une température critique arrête la session, une température élevée active le
mode économie d'énergie. Le composant système applique ces règles même quand
l'app est fermée. Tu peux changer les seuils dans Réglages.

## Ce que DarraOwl modifie

| Réglage | Pendant la session | Retour |
|---|---|---|
| `pmset -a disablesleep` | 1 | la valeur d'avant |
| `pmset -b/-c lowpowermode` | 1, seulement sous le seuil de batterie ou en cas de chaleur | la valeur d'avant, pour chaque profil |

Chaque changement est écrit dans
`/Library/Application Support/DarraOwl/journal.json` avant d'être appliqué.
Une restauration qui échoue reste dans le journal et est retentée toutes les
10 s. Le menu l'affiche.

Journal du composant système :

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "com.darrao.darraowl"'
```

## Mise à jour

Relance `scripts/install-mac.sh`. Le script refuse de continuer pendant
une session : arrête-la d'abord. Une fois l'app remplacée, le composant
système redémarre seul sur la nouvelle version dès qu'il n'a plus rien en
cours. Cela prend au plus 30 s.

## Dépannage

- **Le menu affiche « Composant système en attente de ton autorisation »** :
  ouvre Réglages Système > Général > Ouverture, puis active DarraOwl sous
  **Autoriser en arrière-plan**.
- **Le menu affiche « Le composant système ne répond pas encore »** : dans ce
  même réglage, désactive puis réactive DarraOwl. Le composant système
  rétablit tout avant de s'arrêter, puis redémarre.
- **Journal** : `/usr/bin/log show --last 1h --predicate 'subsystem ==
  "com.darrao.darraowl"'`. Dans zsh, `log` seul désigne une commande interne :
  il faut écrire le chemin complet.

## Désinstallation

```bash
scripts/uninstall.sh          # session arrêtée, réglages rétablis, app supprimée
scripts/uninstall.sh --purge  # supprime aussi les préférences
```

Le script ne lance jamais `sudo`. Si la veille n'a pas pu être rétablie, il
affiche la commande exacte à lancer.

## Développement

```bash
swift test --package-path shared
swift test --package-path mac
scripts/build-mac.sh Debug
```

Les tests utilisent des faux : ils ne lancent jamais `pmset`, iCloud ni le
réseau. Les règles du projet sont dans [CLAUDE.md](CLAUDE.md).
