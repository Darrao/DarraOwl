# Fiche App Store : DarraOwl (iPhone)

À copier dans App Store Connect > DarraOwl > Distribution > version 0.1.0.
Langue principale : Français.

## Informations générales

| Champ | Valeur |
|---|---|
| Nom | DarraOwl |
| Sous-titre (30 car. max) | Ton Mac éveillé, capot fermé |
| Catégorie principale | Utilitaires |
| Catégorie secondaire | Outils de développement |
| Prix | Gratuit |
| URL d'assistance | https://github.com/Darrao/DarraOwl/issues |
| URL marketing | https://github.com/Darrao/DarraOwl |
| URL de la politique de confidentialité | https://github.com/Darrao/DarraOwl/blob/main/PRIVACY.md |
| Copyright | 2026 Darrao |
| Classification par âge | 4+ (répondre « Non » à toutes les questions) |

## Texte promotionnel (170 car. max)

Lance une tâche longue sur ton Mac, ferme le capot et pars. Suis la session, la batterie et tes agents de code depuis ton iPhone.

## Description

DarraOwl garde ton MacBook éveillé, capot fermé, pendant une durée que tu choisis. L'app iPhone te permet de le suivre et de le piloter où que tu sois.

Pensé pour les longues tâches de Claude Code, Codex ou Gemini : tu lances l'agent, tu fermes le capot, tu pars. Ton iPhone te prévient quand l'agent a fini, quand il attend ta validation, ou quand la batterie ne tiendra pas.

SUR L'IPHONE
• État du Mac en direct : session, temps restant, batterie, autonomie, température, capot, réseau
• Agents de code en cours, avec leur projet et s'ils attendent ta validation
• Démarrer, prolonger ou arrêter une session, mettre le Mac en veille
• Docker : conteneurs actifs, pause de Docker Desktop, arrêt d'un conteneur
• Live Activity sur l'écran verrouillé et dans la Dynamic Island, avec les boutons +1 h et Arrêter
• Widgets pour l'écran d'accueil et l'écran verrouillé
• Siri : « Prolonge le Mac d'une heure avec DarraOwl »

CAPOT FERMÉ
Écran et clavier éteints, son coupé, mode économie d'énergie, apps bruyantes mises en pause, Docker en pause s'il ne sert pas. Tout est rétabli à l'ouverture du capot.

SÛR PAR CONCEPTION
• Chaque session a une heure de fin. La veille normale revient toujours, même si l'app plante.
• La session s'arrête si la batterie descend sous ton seuil ou si le Mac chauffe trop.
• Seuls tes iPhone appairés peuvent piloter le Mac, avec des commandes signées. Face ID protège les commandes sensibles.

SANS SERVEUR
Connexion directe chiffrée sur ton réseau ou via Tailscale, sinon par ta propre base iCloud privée. Le développeur ne collecte aucune donnée.

Nécessite l'app DarraOwl pour Mac (macOS 26 ou plus récent, Mac Apple Silicon), disponible gratuitement sur github.com/Darrao/DarraOwl.

## Mots-clés (100 car. max, séparés par des virgules)

veille,mac,macbook,capot,caffeine,amphetamine,claude,agent,code,batterie,session,docker,éveillé,widget

## Nouveautés (première version)

Première version : état du Mac, sessions, agents de code, Live Activity, widgets, notifications et Siri.

## Confidentialité de l'app (App Privacy)

Collecte de données : **Données non collectées**.

Les données restent sur les appareils de l'utilisateur et dans sa base iCloud
privée, à laquelle le développeur n'a pas accès. Selon la définition d'Apple,
ce n'est pas une collecte.

## Conformité export (au premier envoi d'un build)

- L'app utilise-t-elle du chiffrement ? **Oui**.
- Ce chiffrement est-il exempté ? **Oui** : l'app n'utilise que le chiffrement
  standard fourni par iOS (TLS, CryptoKit) pour protéger la liaison avec le Mac
  de l'utilisateur.

C'est toi qui fais cette déclaration.

## Captures d'écran

`docs/app-store/screenshots/`, au format iPhone 6,9" (1320 × 2868), à déposer
dans cet ordre :

1. `1-session.png` : session en cours, agents
2. `2-mac.png` : état du Mac, Docker
3. `3-reglages.png` : réglages capot fermé, alertes, batterie
4. `4-bienvenue.png` : premier lancement

Apple adapte automatiquement ces captures aux autres tailles d'iPhone.

## Notes pour l'équipe de vérification (App Review)

> DarraOwl pilote un Mac qui fait tourner l'app compagnon DarraOwl pour macOS
> (gratuite et open source : https://github.com/Darrao/DarraOwl).
>
> Pour évaluer l'app sans Mac : sur l'écran d'accueil, touchez « Pas encore de
> Mac prêt ? Voir une démonstration ». L'app affiche alors un Mac de
> démonstration, avec une session, des agents, Docker et les réglages. Les
> boutons y fonctionnent. Aucun compte n'est nécessaire.
>
> Avec un Mac : installez l'app Mac, cliquez sur la chouette dans la barre des
> menus, puis iPhone…, puis Afficher le code d'appairage, et scannez le code
> avec l'iPhone.
>
> Le Mac et l'iPhone communiquent directement (TLS avec clé pré-partagée) ou
> via la base CloudKit privée de l'utilisateur. Le développeur n'exploite aucun
> serveur.

## À tester dans TestFlight (champ « What to Test »)

Appairer l'iPhone avec le Mac. Démarrer une session depuis l'iPhone, fermer le
capot, vérifier la Live Activity et la Dynamic Island. Essayer +1 h depuis la
notification ou la Live Activity. Ajouter le widget. Dire à Siri « Prolonge le
Mac d'une heure avec DarraOwl ».
