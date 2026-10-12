# Publier DarraOwl

Deux apps, deux canaux :

- **iPhone** : TestFlight, puis l'App Store. Bundle `com.darrao.darraowl`, app
  « DarraOwl » dans App Store Connect.
- **Mac** : hors App Store, une app signée Developer ID et notarisée par Apple,
  publiée dans les Releases GitHub. Le Mac App Store refuse le composant
  système (root) et impose la sandbox, incompatible avec `pmset`.

Les deux utilisent la base CloudKit **Production** du conteneur
`iCloud.com.darrao.darraowl`.

## Avant chaque version

1. Tests : `swift test --package-path shared`, `swift test --package-path mac`,
   `swift test --package-path ios`. Puis la vérification de bout en bout
   `swift run --package-path tools/link-e2e` : elle ouvre de vraies connexions
   sur ce Mac (réseau local, Bonjour), ce n'est pas un test unitaire.
2. Si un type ou un champ CloudKit a changé : sur icloud.developer.apple.com,
   déploie le schéma de Development vers Production (Deploy Schema Changes).
3. Augmente `MARKETING_VERSION` dans `project.yml` (0.1.0, 0.2.0…).

## Clé App Store Connect (une seule fois)

Les deux scripts d'envoi s'en servent, sans compte Xcode ni mot de passe :

1. App Store Connect > Utilisateurs et accès > Intégrations > App Store Connect
   API > Clés de l'équipe > « + », accès **Développeur**.
2. Télécharge `AuthKey_<ID>.p8` (une seule fois possible) et range-le dans
   `~/.appstoreconnect/private_keys/`.
3. Crée `~/.appstoreconnect/darraowl.env` avec l'ID de la clé et l'Issuer ID
   affiché en haut de la page :

   ```
   ASC_KEY_ID=<ID de la clé>
   ASC_ISSUER_ID=<Issuer ID>
   ```

Rien de tout cela ne va dans le dépôt.

## iPhone : TestFlight

```bash
scripts/testflight.sh
```

Le script archive l'app, la signe pour l'App Store et l'envoie. Dans l'app
TestFlight de l'iPhone, active « Mises à jour automatiques » sur la page de
DarraOwl : chaque build envoyé s'installe seul. Ensuite, dans
App Store Connect > TestFlight :

1. Attends la fin du traitement (10 à 30 min).
2. Si le build passe en « Échec », clique dessus pour lire la raison. Par
   exemple, Apple refuse le mot « Mac » dans les titres, descriptions et
   phrases des raccourcis Siri (ITMS-90626).
3. Réponds à la conformité export : chiffrement exempté (voir `docs/app-store/fiche.md`).
4. Tests internes : ajoute-toi au groupe, puis installe depuis l'app TestFlight.
5. Pour d'autres testeurs, crée un groupe de tests externes et ajoute des
   adresses e-mail, ou génère un lien public. La première version externe passe
   une courte vérification d'Apple (« Beta App Review »).

## iPhone : App Store

Dans App Store Connect > DarraOwl > Distribution :

1. Recopie tout ce qui est dans `docs/app-store/fiche.md` : textes, URL,
   catégorie, mots-clés, confidentialité, notes pour la vérification.
2. Dépose les captures : `docs/app-store/screenshots/iphone-6.3/` dans
   iPhone écran moyen (obligatoire) et `watch/` dans Apple Watch (voir la
   fiche).
3. Confidentialité de l'app : URL de la politique de confidentialité, puis
   « Commencer » > « Non, nous ne collectons pas de données » > Publier.
4. Tarification et disponibilité : Gratuit, tous les pays.
5. Sous Build, choisis le dernier build TestFlight.
6. Clique sur **Ajouter pour vérification**, puis **Soumettre**. La vérification
   prend en général 24 à 48 h. L'équipe d'Apple peut tester sans Mac grâce à
   « Voir une démonstration ».

## Mac : version téléchargeable (GitHub Releases)

### Une seule fois

1. **Certificat Developer ID.** Dans Xcode > Réglages > Comptes, sélectionne
   l'équipe, puis Gérer les certificats > « + » > **Developer ID
   Application**. Seul le titulaire du compte peut le créer : c'est toi.
2. **Notarisation.** La clé App Store Connect (ci-dessus) suffit. Sans elle :
   sur appleid.apple.com > Connexion et sécurité > Mots de passe pour app,
   crée un mot de passe « DarraOwl notarisation », puis dans un Terminal :

   ```bash
   xcrun notarytool store-credentials DarraOwl --apple-id ton@adresse.fr --team-id S3YD258U2R
   ```

### À chaque version

1. Mets `MAC_VERSION` à la nouvelle version dans `project.yml` : les builds
   locaux portent cette version, et la mise à jour automatique remplacerait
   un build local resté derrière la dernière Release.
2. Lance :

   ```bash
   scripts/release-mac.sh 0.2.0
   ```

Le script enchaîne : archive, signature Developer ID (Xcode crée le profil
Developer ID avec iCloud et push), notarisation Apple, agrafage du ticket,
vérification Gatekeeper, puis création de la Release GitHub `v0.2.0` avec le
zip et sa somme SHA-256. Avec `--no-publish`, il prépare tout sans publier.

Les Mac où DarraOwl est installé la trouvent dans la journée et l'installent
seuls quand rien ne tourne (Réglages > Mises à jour).

## Ce que voit quelqu'un qui installe

1. Il télécharge la Release, glisse DarraOwl dans Applications et l'ouvre.
2. La fenêtre de bienvenue le guide : autoriser le composant système (Réglages
   Système > Ouverture), vérifier iCloud, appairer l'iPhone.
3. Il installe l'app iPhone depuis l'App Store ou TestFlight et scanne le
   code.

Ses données restent chez lui : ses appareils et sa propre base iCloud privée.
