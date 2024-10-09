# install_opensearch.sh
Запуск скрипта выполняется следующей командой

./install_opensearch.sh [currentServerNumber] [serverList [ip1:name1,ip2:name2,...]] [paramerter[configonly|installonly|rollback]]

[currentServerNumber] - номер текущего сервера в списке

[serverList [ip1:name1,ip2:name2,...]] - список всех серверов кластера (разделитель запятая для серверов, разделитель двоеточие для данных сервера)

[paramerter[configonly|installonly|rollback]] - необязательный параметр

configonly - только конфигурация, если пакеты уже установлены

installonly - только установка пакетов

rollback - откат изменений при конфигурации пакетов

# install_patroni.sh
Запуск скрипта выполняется следующей командой

./install_patroni.sh [currentServerNumber] [ip1:name1] [ip2:name2] [ip3:name3] [paramerter[configonly|installonly|rollback]]

[currentServerNumber] - номер текущего сервера в списке

[ip1:name1] [ip2:name2] [ip3:name3] - список всех серверов кластера (разделитель пробел для серверов, разделитель двоеточие для данных сервера). Только 3 сервера и все 3 обязательны!

[paramerter[configonly|installonly|rollback]] - необязательный параметр

configonly - только конфигурация, если пакеты уже установлены

installonly - только установка пакетов

rollback - откат изменений при конфигурации пакетов

# install_haproxy.sh
Запуск скрипта выполняется следующей командой

./install_haproxy.sh [serverList [ip1:name1,ip2:name2,...]] [paramerter[configonly|installonly|rollback]]

[serverList [ip1:name1,ip2:name2,...]] - список всех серверов кластера (разделитель запятая для серверов, разделитель двоеточие для данных сервера)

[paramerter[configonly|installonly|rollback]] - необязательный параметр

configonly - только конфигурация, если пакеты уже установлены

installonly - только установка пакетов

rollback - откат изменений при конфигурации пакетов
