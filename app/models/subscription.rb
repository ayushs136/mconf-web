# This file is part of Mconf-Web, a web application that provides access
# to the Mconf webconferencing system. Copyright (C) 2010-2017 Mconf.
#
# This file is licensed under the Affero General Public License version
# 3 or later. See the LICENSE file.

class Subscription < ActiveRecord::Base
  belongs_to :plan
  belongs_to :user

  validates :user_id, :presence => true, :uniqueness => true
  validates :plan_id, :presence => true

  validates :pay_day, :presence => true
  validates :cpf_cnpj, :presence => true
  validates :address, :presence => true
  validates :number, :presence => true
  validates :zipcode, :presence => true
  validates :city, :presence => true
  validates :province, :presence => true
  validates :district, :presence => true
  validates :country, :presence => true

  attr_accessor :payment_token

  before_create :create_customer_and_sub
  before_update :update_sub
  before_destroy :destroy_sub

  def create_customer_and_sub
    if self.plan.ops_type == "IUGU"
      self.customer_token = Mconf::Iugu.create_customer(
                                          self.user.email,
                                          self.user.full_name,
                                          self.cpf_cnpj,
                                          self.address,
                                          self.additional_address_info,
                                          self.number,
                                          self.zipcode,
                                          self.city,
                                          self.province,
                                          self.district,
                                          self.country)

      if self.customer_token == nil
        logger.error "No Token returned from IUGU, aborting"
        errors.add(:ops_error, "No Token returned from IUGU, aborting")
        raise ActiveRecord::Rollback
      elsif self.customer_token["cpf_cnpj"].present? && self.customer_token["zip_code"].present?
        errors.add(:cpf_cnpj, :invalid)
        errors.add(:zipcode, :invalid)
        raise ActiveRecord::Rollback
      elsif self.customer_token["cpf_cnpj"].present?
        errors.add(:cpf_cnpj, :invalid)
        raise ActiveRecord::Rollback
      elsif self.customer_token["zip_code"].present?
        errors.add(:zipcode, :invalid)
        raise ActiveRecord::Rollback
      end

      # Here we are calling the creation of the subscription:
      self.create_sub

    else
      logger.error "Bad ops_type, can't create customer"
      errors.add(:ops_error, "Bad ops_type, can't create customer")
      raise ActiveRecord::Rollback
    end
  end

  def create_sub
    if self.plan.ops_type == "IUGU"
      self.subscription_token = Mconf::Iugu.create_subscription(
                                              self.plan.identifier,
                                              self.customer_token,
                                              self.pay_day)

      if self.subscription_token == nil
        logger.error "No Token returned from IUGU, aborting"
        errors.add(:ops_error, "No Token returned from IUGU, aborting")
        raise ActiveRecord::Rollback
      end

    else
      logger.error "Bad ops_type, can't create subscription"
      errors.add(:ops_error, "Bad ops_type, can't create subscription")
      raise ActiveRecord::Rollback
    end
  end

  # This update function does not cover changes in user full_name or email for now
  def update_sub
    if self.plan.ops_type == "IUGU"
      updated = Mconf::Iugu.update_customer(
                              self.customer_token,
                              self.cpf_cnpj,
                              self.address,
                              self.additional_address_info,
                              self.number,
                              self.zipcode,
                              self.city,
                              self.province,
                              self.district)

      if updated == false
        logger.error "Could not update IUGU, aborting"
        raise ActiveRecord::Rollback
      elsif updated.is_a?(Hash)
        if updated["cpf_cnpj"].present? && updated["zip_code"].present?
          errors.add(:cpf_cnpj, :invalid)
          errors.add(:zipcode, :invalid)
          raise ActiveRecord::Rollback
        elsif updated["cpf_cnpj"].present?
          errors.add(:cpf_cnpj, :invalid)
          raise ActiveRecord::Rollback
        elsif updated["zip_code"].present?
          errors.add(:zipcode, :invalid)
          raise ActiveRecord::Rollback
        end
      end

    else
      logger.error "Bad ops_type, can't update customer"
      errors.add(:ops_error, "Bad ops_type, can't update customer")
      raise ActiveRecord::Rollback
    end
  end

  #def get_sub_data
  #  subscription = Mconf::Iugu.get_subscription(self.subscription_token)
  #end

  # Destroy the customer on OPS, if there's a customer token set in the model.
  def destroy_sub
    if self.plan.ops_type == "IUGU"
      subscription = Mconf::Iugu.destroy_subscription(self.subscription_token)

      if subscription == false
        logger.error "Could not delete subscription from OPS, aborting"
        errors.add(:ops_error, "Could not delete subscription from OPS, aborting")
        raise ActiveRecord::Rollback
      end

      customer = Mconf::Iugu.destroy_customer(self.customer_token)

      if customer == false
        logger.error "Could not delete customer from OPS, aborting"
        errors.add(:ops_error, "Could not delete customer from OPS, aborting")
        raise ActiveRecord::Rollback
      end

    else
      logger.error "Bad ops_type, can't destroy subscription"
    end
  end

  def get_stats_for_subscription
    server = BigbluebuttonServer.default
    server.api.send_api_request(:getStats, { meetingID: self.user.bigbluebutton_room.meetingid })
  end

  def create_invoice
    get_stats = get_stats_for_subscription
    begin
      # All of this should only happen if not during trial months
      if get_stats.present?
        all_meetings = get_stats[:stats][:meeting]
        all_meetings = [all_meetings] unless all_meetings.is_a?(Array)
        # this is scheduled for the first day of the month at 00:00, so it will be covering since the first day of last month
        this_month = all_meetings.reject { |meet| (meet[:epochStartTime].to_i/1000) < (Time.now.to_i-1.month) }
        list_users = this_month.map { |meeting| meeting[:participants][:participant] }.flatten.map { |participant| participant[:userName] }
        # We must replace uniq with the name deduplicator algorithm
        unique_user = list_users.uniq
        unique_total = unique_user.count

        if self.plan.ops_type == "IUGU"
          if unique_total < 15
            # Tax R$ 90,00 minimum fee
            Mconf::Iugu.add_invoice_item(self.subscription_token, I18n.t('.subscriptions.minimum_fee'), "9000", "1")
          elsif unique_total < 250
            # Tax R$ 6,00 per user
            Mconf::Iugu.add_invoice_item(self.subscription_token, I18n.t('.subscriptions.user_fee'), "600", unique_total)
          elsif unique_total < 500
            # Tax R$ 5,40 per user
            Mconf::Iugu.add_invoice_item(self.subscription_token, I18n.t('.subscriptions.user_fee'), "540", unique_total)
          elsif unique_total < 1000
            # Tax R$ 4,80 per user
            Mconf::Iugu.add_invoice_item(self.subscription_token, I18n.t('.subscriptions.user_fee'), "480", unique_total)
          elsif unique_total < 2500
            # Tax R$ 4,20 per user
            Mconf::Iugu.add_invoice_item(self.subscription_token, I18n.t('.subscriptions.user_fee'), "420", unique_total)
          elsif unique_total < 5000
            # Tax R$ 3,60 per user
            Mconf::Iugu.add_invoice_item(self.subscription_token, I18n.t('.subscriptions.user_fee'), "360", unique_total)
          elsif unique_total > 5000
            # Tax R$ 3,00 per user
            Mconf::Iugu.add_invoice_item(self.subscription_token, I18n.t('.subscriptions.user_fee'), "300", unique_total)
          end
        end
      else
        logger.error "get_stats API call has failed"
        raise "get_stats error"
      end
    rescue BigBlueButton::BigBlueButtonException
      logger.error "get_stats API call has failed"
      raise "get_stats error"
    end
  end

end
