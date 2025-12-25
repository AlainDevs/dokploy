ALTER TABLE "application" ADD COLUMN "serviceLabelsSwarm" json;
ALTER TABLE "postgres" ADD COLUMN "serviceLabelsSwarm" json;
ALTER TABLE "mariadb" ADD COLUMN "serviceLabelsSwarm" json;
ALTER TABLE "mongo" ADD COLUMN "serviceLabelsSwarm" json;
ALTER TABLE "mysql" ADD COLUMN "serviceLabelsSwarm" json;
ALTER TABLE "redis" ADD COLUMN "serviceLabelsSwarm" json;
