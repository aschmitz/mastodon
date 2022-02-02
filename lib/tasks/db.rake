# frozen_string_literal: true

namespace :db do
  namespace :migrate do
    desc 'Setup the db or migrate depending on state of db'
    task setup: :environment do
      begin
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
          Your database collation is susceptible to index corruption.
            (This warning does not indicate that index corruption has occurred and can be ignored)
            (To learn more, visit: https://docs.joinmastodon.org/admin/troubleshooting/index-corruption/)
        WARNING
      end
    end
  end

  task :pre_migration_check do
    version = ActiveRecord::Base.connection.select_one("SELECT current_setting('server_version_num') AS v")['v'].to_i
    abort 'ERROR: This version of Mastodon requires PostgreSQL 9.5 or newer. Please update PostgreSQL before updating Mastodon.' if version < 90_500
  end

  Rake::Task['db:migrate'].enhance(['db:pre_migration_check'])
  Rake::Task['db:migrate'].enhance(['db:post_migration_hook'])
end
