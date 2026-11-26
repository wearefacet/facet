---
title: Rôles, niveaux et garde-fou
description: Décidez qui peut modifier les rôles et les comptes, et empêchez les appelants d’élever leurs propres pouvoirs.
audience: [admin, author]
features: [RBC-01, RBC-07]
sidebar:
  order: 7
verified_at: 7a6cb462
---

Un rôle dans Facet est un document ordinaire du doctype `iam.Roles`. Vous le
modifiez comme n’importe quel autre enregistrement. Un garde-fou borne ce
pouvoir. Il décide qui peut changer les identités et les rôles, et dans
quelle mesure.

## Explication

<!-- d2
caller: "Caller elects one role" {class: external}
write: "Write to iam.Account or iam.Roles"
guard: "Authority guard reads the level of the elected role" {class: decision}
denied: "Denied with 403" {class: danger}
applied: "Write applies" {class: ok}

caller -> write
write -> guard
guard -> denied: level too low
guard -> applied: all checks pass
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/c49d8076-light.svg" alt="Caller elects one role" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/c49d8076-dark.svg" alt="Caller elects one role" loading="lazy" />
</div>

Un rôle regroupe des lignes de permission. Une ligne posée sur un doctype
parent couvre aussi ses doctypes enfants. Le tableau détaille les parties
d’une ligne.

| Élément | Contenu |
| --- | --- |
| `action` | `read`, `create`, `update`, `delete`, `*`, ou une action nommée comme `promote` |
| `on` | un chemin de doctype, comme `production.Project` |
| `scope` | des périmètres de lignes nommés sur le doctype, facultatifs, combinés en un OU logique |
| `except` | des chemins de doctypes soustraits de la portée, facultatifs |

À côté de ses lignes, un rôle porte `visible_tags`. Un champ n’est visible
que si toutes ses étiquettes figurent dans cette liste. Le rôle porte aussi
un niveau de 0 à 100. Le niveau est obligatoire, et il classe les rôles selon
leur autorité.

**Le niveau classe les rôles.** Une requête s’exécute sous exactement un rôle
élu. Les rôles ne fusionnent jamais. Le garde-fou lit le niveau du rôle élu,
pas celui du rôle le plus élevé que l’appelant porte.

### Ce que couvre le garde-fou

Chaque écriture pilotée par l’appelant sur `iam.Account` et `iam.Roles` passe
par un seul garde-fou. Il couvre la création, la modification et la
suppression de documents, les actions nommées, et les transitions de retour
arrière. Il s’exécute après la validation. Même quand une route saute la
vérification d’autorisation, le garde-fou s’applique. Une écriture refusée
répond `403` avec le détail. Seuls les appels système internes le
contournent.

| Vérification | Règle |
| --- | --- |
| Niveau de l’appelant | Lu dans le `level` du rôle élu. Un niveau absent ou mal formé refuse l’écriture. |
| Affectation des rôles | Chaque rôle du tableau final `roles` doit exister, ne pas être supprimé, et se situer au niveau de l’appelant ou en dessous. `default_role` doit figurer dans `roles`. |
| Protection de la cible | Aucune écriture vers un compte au plafond de rôles plus élevé, ni vers un rôle de niveau plus élevé. |
| Définition des rôles | Le niveau résultant ne doit pas dépasser le niveau de l’appelant. Chaque ligne de permission résultante doit être impliquée par le rôle précédent ou par le rôle de l’appelant. Les nouvelles `visible_tags` doivent rester dans l’union des deux. |

Cet encadrement couvre aussi les autres champs de pouvoir d’un rôle. Une
écriture ne peut pas pousser les canaux de connectivité ni le budget de
l’assistant au-del à de ce qu’un rôle de référence implique. Une écriture qui
ajoute un champ de pouvoir inconnu est refusée.

**Le même niveau suffit pour affecter.** Un appelant peut affecter un rôle
existant à son propre niveau, même si ce rôle porte des permissions qui lui
manquent. Mais un appelant ne peut pas créer un rôle au-dessus de son niveau.
Et il ne peut pas élargir un rôle au-del à de ce que le rôle précédent ou son
propre rôle implique. Ces changements exigent un administrateur de niveau
supérieur.

:::caution
Un changement qui ne fait que restreindre reste une écriture. Un appelant de
niveau 90 ne peut pas modifier un compte dont le plafond est 100, pas même
pour lui retirer des rôles. La protection de la cible bloque d’abord le
changement.
:::

**Le compromis.** Le garde-fou empêche un appelant d’élever sa propre
autorité. Le prix, c’est la friction. Abaisser un compte élevé ou élargir un
rôle exige un administrateur à un niveau supérieur. Les rôles ne s’imbriquent
pas et n’héritent pas. Le niveau classe les rôles ; il ne propage pas les
droits. Chaque rôle liste la totalité de ses propres permissions.

## Voir aussi

- [Gouverner l’accès](/fr/admin/) — modifiez les rôles et les comptes au quotidien.
- [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/) — comment les lignes de permission deviennent des vérifications en lecture et en écriture.
- [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/) — comment le rôle élu voyage avec chaque requête.
- Internes sur GitHub : [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md).
