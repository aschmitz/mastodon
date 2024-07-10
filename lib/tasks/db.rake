# frozen_string_literal: true

require_relative '../mastodon/snowflake'

def each_schema_load_environment
  # If we're in development, also run this for the test environment.
  # This is a somewhat hacky way to do this, so here's why:
  # 1. We have to define this before we load the schema, or we won't
  #    have a timestamp_id function when we get to it in the schema.
  # 2. db:setup calls db:schema:load_if_ruby, which calls
  #    db:schema:load, which we define above as having a prerequisite
  #    of this task.
  # 3. db:schema:load ends up running
  #    ActiveRecord::Tasks::DatabaseTasks.load_schema_current, which
  #    calls a private method `each_current_configuration`, which
  #    explicitly also does the loading for the `test` environment
  #    if the current environment is `development`, so we end up
  #    needing to do the same, and we can't even use the same method
  #    to do it.

  if Rails.env.development?
    test_conf = ActiveRecord::Base.configurations.find_db_config('test')

    if test_conf&.database&.present?
      ActiveRecord::Base.establish_connection(:test)
      yield
      ActiveRecord::Base.establish_connection(Rails.env.to_sym)
    end
  end

  yield
end

# We are providing our own task with our own format
Rake::Task['db:encryption:init'].clear

namespace :db do
  namespace :encryption do
    desc 'Generate a set of keys for configuring Active Record encryption in a given environment'
    task :init do # rubocop:disable Rails/RakeEnvironment
      puts <<~MSG
        Add these secret environment variables to your Mastodon environment (e.g. .env.production):#{' '}

        ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=#{SecureRandom.alphanumeric(32)}
        ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=#{SecureRandom.alphanumeric(32)}
        ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=#{SecureRandom.alphanumeric(32)}
      MSG
    end
  end

  namespace :migrate do
    desc 'Setup the db or migrate depending on state of db'
    task setup: :environment do
      if ActiveRecord::Migrator.current_version.zero?
        Rake::Task['db:migrate'].invoke
        Rake::Task['db:seed'].invoke
      end
    rescue ActiveRecord::NoDatabaseError
      Rake::Task['db:setup'].invoke
    else
      Rake::Task['db:migrate'].invoke
    end
  end

  task :migrate do
    # We do this after every migration so we don't have to deal with
    # setting up timestamp_id as a default every time we create a
    # table, which would inevitably be forgotten at some point.
    Rake::Task['db:ensure_ids_are_timestamp_based'].execute
  end

  # Before we load the schema, define the timestamp_id function.
  # Idiomatically, we might do this in a migration, but then it
  # wouldn't end up in schema.rb, so we'd need to figure out a way to
  # get it in before doing db:setup as well. This is simpler, and
  # ensures it's always in place.
  Rake::Task['db:schema:load'].enhance ['db:define_timestamp_id']

  # After we load the schema, make sure we have sequences for each
  # table using timestamp IDs.
  Rake::Task['db:schema:load'].enhance do
    Rake::Task['db:ensure_id_sequences_exist'].invoke
  end

  task :define_timestamp_id do
    each_schema_load_environment do
      Mastodon::Snowflake.define_timestamp_id
    end
  end

  task :ensure_ids_are_timestamp_based do
    each_schema_load_environment do
      conn = ActiveRecord::Base.connection

      # First, make sure we have a `timestamp_id` function.
      Mastodon::Snowflake.define_timestamp_id

      # Now, see if there are any tables using sequential IDs.
      conn.tables.each do |table|
        # We're only concerned with "id" columns.
        next unless (id_col = conn.columns(table).find { |col| col.name == 'id' })

        # And only those that are still using serials.
        next unless id_col.serial?

        # Make sure they're using a bigint, not something else.
        if id_col.sql_type != 'bigint'
          Rails.logger.warn "Table #{table} has an non-bigint ID " \
                            "column (#{id_col.sql_type}), leaving it alone."
          next
        end

        # Make them use our timestamp IDs instead.
        alter_query = "ALTER TABLE #{conn.quote_table_name(table)}
          ALTER COLUMN id
          SET DEFAULT timestamp_id(#{conn.quote(table)})"
        conn.execute(alter_query)
      end
    end
  end

  task :ensure_id_sequences_exist do
    each_schema_load_environment do
      Mastodon::Snowflake.ensure_id_sequences_exist
    end
  end

  task :post_migration_hook do
    at_exit do
      unless %w(C POSIX).include?(ActiveRecord::Base.connection.select_one('SELECT datcollate FROM pg_database WHERE datname = current_database();')['datcollate'])
        warn <<~WARNING
          Your database collation may be susceptible to index corruption.
            (This warning does not indicate that index corruption has occurred, and it can be ignored if you've previously checked for index corruption)
            (To learn more, visit: https://docs.joinmastodon.org/admin/troubleshooting/index-corruption/)
        WARNING
      end
    end
  end

  task pre_migration_check: :environment do
    version = ActiveRecord::Base.connection.database_version
    abort 'This version of Mastodon requires PostgreSQL 12.0 or newer. Please update PostgreSQL before updating Mastodon.' if version < 120_000
  end

  Rake::Task['db:migrate'].enhance(['db:pre_migration_check'])
end
