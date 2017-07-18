# frozen_string_literal: true
# == Schema Information
#
# Table name: mutes
#
#  id                 :integer          not null, primary key
#  account_id         :integer          not null
#  target_account_id  :integer          not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  hide_notifications :boolean          default(FALSE), not null
#

class Mute < ApplicationRecord
  include Paginable

  belongs_to :account, required: true
  belongs_to :target_account, class_name: 'Account', required: true

  validates :account_id, uniqueness: { scope: :target_account_id }

  after_create  :remove_blocking_cache
  after_destroy :remove_blocking_cache

  private

  def remove_blocking_cache
    Rails.cache.delete("exclude_account_ids_for:#{account_id}")
  end
end
