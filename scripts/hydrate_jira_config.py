import re
from os import environ
import sys


def get_parameters(env_variables):
  parameters = {}
  for env_var in env_variables:
    ev_key = env_var.lower().replace('_', '.')
    ev_value = environ.get(env_var, '')
    parameters[ev_key] = ev_value
  return parameters


def process_line(pattern, line, parameters):
  matches = pattern.findall(line)
  if not matches:
    return line

  for parameter in matches:
    substitution = parameters.get(parameter, None)
    if substitution:
      line = line.replace('${%s}' % parameter, substitution)

  return line


def main():
  dbconfig_xml_env_variables = [
      'DB_SERVER_NAME',
      'DB_TRUSTED_HOST',
      'DB_NAME',
      'DB_USER',
      'DB_PASSWORD',
      'DB_SCHEMA',
      'DB_PORT',
      'DB_TYPE',
      'DB_JDBCURL',
      'DB_DRIVER_CLASS',
      'DB_CONFIG_TYPE'
  ]

  server_xml_env_variables = [
      'SERVER_APP_PORT',
      'SERVER_PROXY_NAME',
      'SERVER_PROXY_PORT',
      'SERVER_APP_SCHEME',
      'SERVER_CLUSTER_NAME',
      'SERVER_CATALINA_HOME',
      'SERVER_SECURE_FLAG'
  ]

  db_sql_env_variables = [
      'DB_NAME',
      'USER_ENCRYPTION_METHOD',
      'USER_FULLNAME',
      'USER_FULLNAME_LOWERCASE',
      'USER_NAME',
      'USER_NAME_LOWERCASE',
      'USER_FIRSTNAME',
      'USER_FIRSTNAME_LOWERCASE',
      'USER_LASTNAME',
      'USER_LASTNAME_LOWERCASE',
      'USER_EMAIL',
      'USER_EMAIL_LOWERCASE',
      'USER_PASSWORD',
      'JIRA_LICENSE',
      'APPLICATION_TITLE',
      'BASEURL',
      'SERVER_ID',
      'DB_SCRIPT_NAME_LOC'
  ]

  misc_env_variables = [
  	'APPINSIGHTS_VER',
    'APPINSIGHTS_INSTRUMENTATION_KEY'
  ]

  env_variables = ( \
    dbconfig_xml_env_variables + \
    server_xml_env_variables + \
    db_sql_env_variables + \
    misc_env_variables
  )

  parameters = get_parameters(env_variables)
  parameter_pattern = re.compile(r"\$\{([a-zA-Z0-9\.]*)\}")

  for line in sys.stdin:
    transformed_line = process_line(parameter_pattern, line, parameters)
    sys.stdout.write(transformed_line)


if __name__ == '__main__':
  main()
