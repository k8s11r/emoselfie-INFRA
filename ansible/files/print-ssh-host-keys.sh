#!/bin/sh
# ansible/playbooks/known-hosts.yml이 설치한다. 직접 고치지 않는다.
#
# cloud-init은 인스턴스의 첫 부팅에만 SSH 호스트 키 지문을 콘솔에 남긴다
# (keys_to_console이 PER_INSTANCE). 그래서 중지 후 시작한 인스턴스는 AWS 부팅
# 로그(ec2:GetConsoleOutput)로 호스트 키를 검증할 수 없다. 부팅할 때마다 같은
# 형식으로 다시 남긴다. cloud-init의 scripts_per_boot가 매 부팅 이 파일을 실행한다.
#
# /dev/console은 커널 인자의 마지막 console=ttyS0으로 이어져 부팅 로그에 잡힌다.
{
  echo "-----BEGIN SSH HOST KEY FINGERPRINTS (emoselfie per-boot)-----"
  for key in /etc/ssh/ssh_host_*_key.pub; do
    if [ -f "$key" ]; then
      ssh-keygen -l -f "$key"
    fi
  done
  echo "-----END SSH HOST KEY FINGERPRINTS (emoselfie per-boot)-----"
} > /dev/console 2>&1
