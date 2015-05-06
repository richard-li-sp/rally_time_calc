sudo docker run \
  --name rally_time_calc --rm \
  -v /etc/rally_time_calc.yml:/code/rally_time_calc.yml:ro \
  -v /tmp/rally_time_calc.log:/var/log/rally_time_calc.log:rw \
  docker.cloud.sailpoint.com/richardli/rally_time_calc:latest
