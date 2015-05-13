sudo docker run -it \
  --name rally_time_calc --rm \
  -v /vagrant/dev/rally_time_calc:/code:rw \
  -v /etc/rally_time_calc.yml:/code/rally_time_calc.yml:ro \
  -v /tmp/rally_time_calc.log:/var/log/rally_time_calc.log:rw \
  ${DOCKER_REGISTRY}/${DOCKER_REGISTRY_USER}/rally_time_calc:latest \
  /bin/bash
