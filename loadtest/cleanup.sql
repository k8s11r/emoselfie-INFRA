-- loadtest/seed.py 가 만든 시드 데이터 정리.
-- rooms 삭제는 participants/rounds/submissions까지 CASCADE로 지운다
-- (app/db/models.py의 ondelete="CASCADE"). users는 별도로 지운다.
--
-- 실행 예 (postgres StatefulSet pod, 이미 컨테이너 안에 POSTGRES_USER/DB env가 있음):
--   kubectl exec -i postgres-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < loadtest/cleanup.sql

DELETE FROM rooms WHERE invite_slug LIKE 'loadtest-%';
DELETE FROM users WHERE nickname = 'lt';
