---
title: Performances et dimensionnement
description: À quelle vitesse une instance Facet répond sous une charge réelle, et comment dimensionner un déploiement.
type: reference
audience: [operator, evaluator]
features: [AUT-04, PLT-05, PLT-13]
sidebar:
  order: 1
verified_at: 9aea50f
---

**En bref :** une instance de Facet sur une machine moderne traite environ
**300 opérations par seconde** en trafic mixte soutenu. La plupart des
lectures répondent en **20 à 30 ms**, les écritures en **5 à 100 ms** selon
la charge. Pendant notre essai de 20 minutes avec 20 clients et 4,6 millions
de documents, **aucune requête n’a échoué**.

L’essentiel de ce temps se passe dans **PostgreSQL**, pas dans Facet. La
vitesse de votre déploiement dépend donc d’abord de la configuration de votre
base. Voir [Où passe le temps](#où-passe-le-temps).

---

## Configuration du test

| | |
|---|---|
| Version de Facet | 0.2.3 (images Docker backend + frontend, configuration par défaut) |
| Machine | Station de travail de classe AMD Strix, une seule machine qui héberge Facet, PostgreSQL et le générateur de charge |
| Topologie | **1** processus Facet, **1** instance PostgreSQL, Caddy en entrée |
| Limite mémoire | 10 Go pour le conteneur Facet |
| Jeu de données | Un seul type de document (`Invoice`, ~20 champs, 74 indexés), passé de **2,5 M à 4,7 M de documents** (14 Go) pendant l’essai |
| PostgreSQL | 17 (`pgvector/pgvector:0.8.0-pg17`), même machine, NVMe local |
| Réglages PostgreSQL | `max_connections = 200`, `shared_buffers = 128 MB`, `work_mem = 4 MB`, `effective_cache_size = 4 GB`, `synchronous_commit = on`, `max_parallel_workers_per_gather = 2` ; pool de connexions de Facet à sa taille par défaut |

C’est une machine unique, sans réplique ni couche de cache. Un déploiement
serveur classique installe PostgreSQL sur sa propre machine ; attendez-vous à
des chiffres égaux ou meilleurs. Voir plus bas la section
[Sur un serveur de production](#sur-un-serveur-de-production).

---

## À quoi s’attendre

### Usage courant (charge mixte)

20 clients simultanés pendant 20 minutes, contre 4,6 M de documents. 75 % du
trafic était des lectures (listes, filtres, tris, lecture par identifiant) et
25 % des écritures (mises à jour et créations).

| | |
|---|---:|
| Débit | **311 op/s** (~1,1 M d’opérations/heure) |
| Latence de lecture, p50 / p95 | **45 ms / 98 ms** |
| Latence d’écriture, p50 / p95 | **108 ms / 230 ms** |
| Erreurs | **0** sur 373 884 requêtes |

### Lectures

2,5 M de documents, 8 clients simultanés. Toutes les valeurs en ms.

| Requête | p50 | p95 |
|---|---:|---:|
| Lecture par identifiant | 12 | 31 |
| Liste (page par défaut) | 24 | 39 |
| Comptage | 18 | 35 |
| Historique d’un document | 18 | 27 |
| Filtre sur un champ indexé (égalité, intervalle, pays…) | 26–29 | 42–49 |
| Filtre plein texte sur un champ indexé | 31 | 62 |
| Tri sur n’importe quel champ indexé ou sur la date de création | 22–23 | 36–42 |
| Pagination des résultats (500 premières lignes) | 22 | 39 |
| Pagination profonde (ligne ~5 000) | 102 | 144 |
| Lignes imbriquées (100 par document) | 50 | 78 |
| **Agrégats (`sum`, …) sur toute la table** | **1 037** | **2 732** |
| **Recherche globale** | **807** | **1 555** |

Toute requête qui utilise un index est rapide, et sa vitesse dépend à peine de
la taille de la table. Deux familles de requêtes restent lentes sur les
grandes tables :

- **Les agrégats et la recherche sur des millions de documents** prennent
  environ 1 s. Resserez le filtre, ou exécutez-les en tâche de fond.
- **La pagination par décalage très profonde** (la page 100 000, par exemple)
  prend 2 à 3 s. Filtrez ou triez pour atteindre les lignes voulues plutôt que
  de paginer jusque-là.

Un filtre sur un champ sans index est refusé avec un `422` qui liste les
champs sur lesquels vous pouvez filtrer. Facet ne retombe jamais sur un
balayage lent sans le dire.

### Écritures

| Écrivains simultanés | Créations/s | p50 | p95 |
|---:|---:|---:|---:|
| 1 | 250 | 4 ms | 5 ms |
| 4 | 320 | 11 ms | 23 ms |
| 8 | 350 | 22 ms | 36 ms |
| 32 | 320 | 99 ms | 139 ms |
| 128 | 285 | 428 ms | 641 ms |

Les mises à jour (`PATCH`, 8 écrivains) tiennent **350/s**, avec un p50 de
20 ms et un p95 de 47 ms.

**Une instance plafonne à environ 300 à 350 écritures par seconde.** Au-delà,
des clients supplémentaires n’ajoutent pas de débit : ils font attendre
chaque requête plus longtemps.

### Import en masse

| | |
|---|---:|
| Une tâche d’import | ~440 lignes/s (100 k lignes en ~4 min) |
| 2 tâches en parallèle (le maximum par défaut) | ~720 lignes/s au total |
| 1 M de lignes | ~23 min |
| 2 M de lignes | ~46 min |

La mémoire reste bornée. Un import de 100 k lignes ajoute environ 0,6 Go, et
plusieurs imports volumineux lancés ensemble ont culminé à environ 6 Go.
Quand les imports se terminent, la mémoire redescend vers 1 Go. Au plus
2 imports tournent en même temps (le plafond propre à l’import, à
l’intérieur de `jobs.max_concurrent`) ; les tâches suivantes attendent dans
la file.

### Surcharge

| Écrivains simultanés | Résultat |
|---:|---|
| jusqu’à 128 | toutes les requêtes aboutissent |
| 256 | 7,5 % refusées avec `503` |
| 512 | 87 % refusées avec `503` |

En surcharge, Facet **refuse vite les requêtes et dit pourquoi** avec
`503 {"error":"Service unavailable","dependency":"postgresql"}`, et continue
de servir celles qu’il accepte. Il ne se bloque pas et n’expire pas. Les
clients peuvent réessayer avec un backoff.

---

## Où passe le temps

Chaque limite ci-dessus vient de PostgreSQL.

| Limite | Ce qui la fixe | Ce qui la lève |
|---|---|---|
| **~300 écritures/s** | Chaque écriture passe environ **3 ms dans PostgreSQL** : 1,6 ms pour mettre à jour le document, 1,4 ms pour l’ajouter à l’historique. 300 écritures/s × 3 ms ≈ 1 s de temps de base par seconde : les écritures passent donc une à une. Le plafond, c’est la vitesse à laquelle PostgreSQL termine une écriture. | Réduire la latence de commit : stockage NVMe rapide, PostgreSQL sur sa propre machine, réglages du WAL et du commit. Ajouter des threads à Facet ne change rien. |
| **~1 s pour les agrégats et la recherche** | PostgreSQL balaye des millions de lignes | Plus de RAM pour le cache, `work_mem`, des workers de requêtes parallèles, ou un filtre plus étroit |
| **Pagination profonde** | PostgreSQL saute les lignes précédentes | Filtrer ou trier plutôt que paginer loin |
| **`503` en surcharge** | Plus aucune connexion de base libre (`max_connections`, taille du pool) | Plus de connexions, ou un pooler de connexions |

Facet, lui, reste léger : environ un cœur de processeur et 1 à 2 Go de
mémoire. L’import en masse fait exception, car Facet décode les lignes sur
son propre processeur.

---

## Guide de dimensionnement

| Si vous avez besoin… | Déployez |
|---|---|
| Jusqu’à ~300 op/s en mixte, ou ~300 écritures/s (≈ 1 M d’écritures/heure) | **1 instance** |
| Plus de débit en écriture | **Un PostgreSQL plus rapide** (stockage, machine dédiée, réglages de commit). Lancer plusieurs processus Facet n’a pas encore été mesuré. |
| Des rapports rapides sur des millions de lignes | Des requêtes filtrées ou des tâches de fond ; les agrégats sur toute la table prennent ~1 s |
| Une grande migration initiale de données | Comptez ~25 min par million de lignes |

Mémoire : prévoyez **2 Go** pour le processus Facet en usage normal, et
**8 Go** si vous lancez des imports parallèles volumineux.

## Sur un serveur de production

Concentrez votre effort de dimensionnement sur **PostgreSQL**.

- **La latence du stockage fixe la limite d’écriture.** Prenez du NVMe local,
  ou une base gérée à faible latence de commit. Des disques réseau lents
  ramènent les ~300 écritures/s d’autant.
- **Donnez à PostgreSQL assez de RAM pour garder vos données actives en
  cache.** Les lectures de cet essai répondent en 20 à 30 ms parce que les
  index et les données récentes restent en mémoire.
- **Installez PostgreSQL sur sa propre machine.** Dans cet essai, PostgreSQL,
  Facet et le générateur de charge partageaient la même machine.
- **Accordez assez de connexions à la base** (`max_connections`). Manquer de
  connexions est la première limite atteinte en surcharge.
- Facet lui-même demande **1 à 2 cœurs de processeur et 2 Go de mémoire**,
  ou 8 Go si vous lancez des imports parallèles volumineux.

## Reproduire ces chiffres

- Installez la version **0.2.3 ou plus récente**. Les index et les
  statistiques du planificateur dont ces chiffres dépendent sont créés
  automatiquement à l’installation.
- **Lancez `ANALYZE projections;` après un premier import massif.** PostgreSQL
  a besoin de statistiques fraîches pour bien planifier les requêtes.
  L’autovacuum finit par y arriver tout seul, mais lancer `ANALYZE`
  vous-même rend les requêtes rapides tout de suite.
- Si vous avez **mis à niveau depuis une version antérieure**, suivez les
  [notes de mise à niveau 0.2.3](/fr/admin/keep-running/upgrades/) pour
  ajouter les nouveaux index et statistiques à votre base existante. Sans
  eux, les filtres et les tris par date sur les grandes tables peuvent être
  jusqu’à 100× plus lents.

## Voir aussi

- [Prérequis système](/fr/admin/install/requirements/) — ce dont une machine a besoin pour faire tourner Facet.
- [Mettre à niveau Facet](/fr/admin/keep-running/upgrades/) — les notes de déploiement que chaque version embarque, dont la 0.2.3.
- [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/) — les compteurs à surveiller sous charge.
- [Limites](/fr/reference/limits/) — les plafonds exacts et les clés de configuration qui les portent.
