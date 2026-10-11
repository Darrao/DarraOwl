# Politique de confidentialité de DarraOwl

Dernière mise à jour : 11 octobre 2026

DarraOwl se compose d'une app pour Mac et d'une app pour iPhone. Elles
communiquent directement entre elles, ou via ta propre base de données iCloud
privée. **Le développeur ne collecte aucune donnée.** Aucun serveur tiers
n'intervient, et l'app ne contient ni publicité, ni outil de mesure
d'audience, ni pistage.

## Ce qui reste sur tes appareils

- Les clés d'appairage : elles sont dans le trousseau de chaque appareil et ne
  sont jamais synchronisées.
- Le journal des changements faits sur le Mac (veille, luminosité, son, apps
  mises en pause) : il est stocké sur le Mac.
- Les réglages.

## Ce qui passe par ta base iCloud privée

Seulement si la connexion directe entre l'iPhone et le Mac n'est pas
possible :

- l'état du Mac : session en cours, batterie, température, type de réseau et
  data consommée, noms des agents de code en cours (claude, codex, gemini) et
  de leurs dossiers de projet (ces noms peuvent être masqués dans les
  réglages), conteneurs Docker en cours, et en mode agent le nom de la
  commande suivie (jamais ses arguments) ;
- les adresses réseau du Mac (locale, Tailscale), pour la connexion directe ;
- les commandes envoyées par l'iPhone, signées, et leurs résultats ;
- le titre et le texte des notifications (par exemple « Claude a fini », avec
  le nom du projet).

Ces données sont enregistrées dans ta base de données iCloud **privée**, que
seul ton compte Apple peut lire. Le contenu des états et des commandes est
chiffré par iCloud. Le développeur n'y a pas accès.

DarraOwl n'envoie **jamais** le contenu de tes fichiers, tes prompts ni ce que
produisent tes agents de code. Pour les hooks de Claude Code, seuls le nom de
l'événement et le nom du dossier sont lus. Ces hooks ne sont ajoutés à
`~/.claude/settings.json` que si tu cliques sur Activer.

## Réseau local, caméra, Face ID, notifications

- **Réseau local** : pour joindre ton Mac directement. La connexion est
  chiffrée (TLS) avec une clé propre à chaque iPhone appairé.
- **Caméra** : uniquement pour scanner le code d'appairage. Aucune image n'est
  conservée.
- **Face ID** : il confirme les commandes sensibles. La vérification a lieu sur
  l'iPhone, dans la Secure Enclave. DarraOwl ne voit jamais ton visage.
- **Notifications** : elles sont envoyées par iCloud, sur demande du Mac, sans
  serveur du développeur.

## Supprimer tes données

- Sur l'iPhone : « Désappairer cet iPhone », ou supprime l'app.
- Sur le Mac : `scripts/uninstall.sh`. Il supprime les clés d'appairage et les
  données iCloud de DarraOwl.
- Tu peux aussi effacer les données d'iCloud dans Réglages > [ton nom] >
  iCloud > Gérer le stockage.

## Contact

Pour toute question, ouvre un ticket sur
https://github.com/Darrao/DarraOwl/issues.
