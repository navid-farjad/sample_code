=begin
This is a sample code by Navid Farjad includes:

- route
- model
- channel
- controller
- RSpec
- interaction

=end

# here is a sample route which connects our Engines to our supercharged engine
Rails.application.routes.draw do
  mount ActionCable.server => '/cable'

  namespace :api do
    mount Access::Engine, at: '/access'
    mount HumanResource::Engine, at: '/human_resource'
    mount Company::Engine, at: '/company'
    mount Chat::Engine, at: '/chat'
  end
end

module HumanResource
  class Engine < ::Rails::Engine
    isolate_namespace HumanResource
  end
end


# this is a sample model with some random validation, associations and callbacks
module HumanResource
  class Account < ApplicationRecord
    searchkick

    include ActiveModel::Validations
    validates_with CustomSampleValidator, unless: :is_premium_company?
    after_validation :set_gravatar, on: [:create, :update],
                     if: [:subject_to_public_view?, :contractor?]

    belongs_to :company
    belongs_to :user

    has_one_attached :avatar, dependent: :destroy
    has_one_attached :theme_background, dependent: :destroy

    has_many :account_tokens, dependent: :destroy
    has_many :tickets
    has_many :assigned_tickets, -> { where open: true, unassigned: false }, class_name: 'Ticket'
    has_many :pending_tickets, -> { where open: true, pending: true }, class_name: 'Ticket'
    has_many :today_closed_tickets, -> { where open: false, created_at: Time.now..Time.now - 8.hour }, class_name: 'Ticket'
    has_many :starred_tickets, through: :ticket_stars, source: :ticket

    scope :payment_verified, -> { where(payment_verified: true) }
    scope :trusted_payment_verified, -> { payment_verified.where('deposit > 500') }

    enum :status, [:active, :hold, :cancelled]

    private

    def serializable_hash(options = nil)
      options ||= {}
      super(options.merge(except: %i[registration_token pre_invitation_token digest_email])).merge(
        avatar: avatar_url,
        theme_background_url: theme_background_url,
        email: user.email
      )
    end

    def search_data
      { id: id,
        company_id: company_id,
        first_name: first_name,
        last_name: last_name,
        admin: admin,
        chat: chat,
        report: report,
        general_team: general_team,
        on_duty: on_duty,
        created_at: created_at,
        updated_at: updated_at,
        team_agent_ids: team_agent_ids }
    end

    def set_gravatar
      self.avatar = ::Api::Account::Gravatar::Init.run!(account: self)

    end

    def avatar_url
      avatar.gravatar || 'https://storage.googleapis.com/domain/' + avatar.attachment.blob.key.to_s
    end
  end
end

class CustomSampleValidator < ActiveModel::Validator
  def validate(account)
    if check_account_credit
      account.errors.add(:base, "This account is invalid")
    end
  end

  private

  def check_account_credit
    ::Api::Account::Credit::Show.run!(account: current_account, status: true) > 5.00
  end

  #...
end

# sample channel
class DutyChannel < ApplicationCable::Channel
  def subscribed
    reject and return if current_account.blank?
    stream_from "duty_#{current_account.id}"
    ::Api::Ticket::Agent::OnDuty::Update.run!(account: current_account, status: true)
    ::Api::Agent::Agent::BroadcastUpdate.run!(agent_id: current_account.id, company_id: current_account.company_id)
  end

  #...
end

# sample controller
module HumanResource
  class ::Api::Account::InfoController < ApplicationController
    skip_before_action :authenticate_with_token!, only: [:update, :show]

    def index
      result = ::Api::Account::Info::Index.run!(params.merge(account: current_account,
                                                             company: current_account.company))

      render json: { accounts: result.accounts,
                     next_page: result.next_page,
                     total_pages: result.total_pages,
                     total_count: result.total_count,
                     took: result.took,
                     aggs: result.aggs }
    end

    def show
      account = ::Api::Account::Info::Show.run!(params.merge(account: current_account))
      render json: { account: account, company: account.company }
    end

    def update
      account = ::Api::Account::Info::Update.run!(params.merge(account: current_account))
      render json: { account: account }
    end

  end
end


# sample RSpec
RSpec.describe Ticket, :type => :model do
  it "creates ticket and validates tasks and access level " do
    accounting_user = Account.create(:email => 'a1@aa.com', :password => 'pw1234')
    management = Account.create(:email => 'a1@bb.com', :password => 'pw1234')

    ticket {
      ::Api::Ticket::Create.run!(subject: 'Test ticket', description: 'Lorem ipsum',
                                 start_date: DateTime.now, task_due: DateTime.now + 1.week,
                                 user_id: accounting_user.id, reported_id: management.id)

    }

    it "is valid with valid access level" do
      expect(ticket).to be_valid
    end

    it "is not valid without a subject" do
      ticket.title = nil
      expect(ticket).to_not be_valid
    end

    # ...

  end
end

# sample interaction
class ::Api::Account::Info::Index < ActiveInteraction::Base
  object :account
  object :company
  string :q, default: '*'
  integer :page, default: 1
  integer :per_page, default: 100
  boolean :load, default: true
  array :account_ids, default: nil
  array :non_account_ids, default: nil
  boolean :admin, default: nil
  boolean :chat, default: nil
  boolean :on_duty, default: nil
  boolean :account_sorted, default: false
  array :accounts_boosted, default: nil
  array :team_ids, default: nil

  SEARCHES_FIELDS = %i[first_name last_name]

  def execute
    order = { first_name: :desc }
    boost_where = {}
    if account_sorted
      boost_where = { id: accounts_boosted }
      order = {}
    end

    args = retrieve_args
    aggs = retrieve_aggs
    res = Account.search(
      q,
      boost_where: boost_where,
      fields: SEARCHES_FIELDS,
      where: args,
      order: order,
      load: load,
      aggs: aggs,
      page: page,
      per_page: per_page,
    )

    # and this might go as
    # ::Api::Conversation::Message::NotificationEmail.run!(ticket: account.ticket, description_txt: description_txt)

    if unavailable_agent_possibility and !conversation.online_client
      Thread.new do
        unless notify_accounts.email_token.blank? || !company.email_domain_verified
          from_email = 'support@' + company.email_domain
          TicketMailer.send_message(conversation.ticket.subject,
                                    notify_accounts.user.email,
                                    from_email,
                                    description_txt).deliver
        end

        ::Api::Conversation::Message::Broadcast.run!(message: message, action: 'Create')
      end
    end

    [res.results, res.next_page, res.total_pages, res.total_count, res.took, res.aggs]
  end

  private

  def retrieve_args
    args = {}

    args[:admin] = admin unless admin.nil? || admin.empty?
    args[:chat] = chat unless chat.nil? || chat.empty?
    args[:on_duty] = on_duty unless on_duty.nil? || on_duty.empty?
    args[:company_id] = company.id
    args[:id] = { not: non_account_ids.map(&:to_i) } unless non_account_ids.blank? || non_account_ids.empty?
    args[:id] = account_ids.map(&:to_i) unless account_ids.blank? || account_ids.empty?
    args[:team_ids] = team_ids.map(&:to_i) unless team_ids.blank? || team_ids.empty?

    args
  end

  def retrieve_aggs
    aggs = {}
    limit_ranges = [{ to: 20 }, { from: 20, to: 50 }, { from: 50 }]
    aggs[:score] = { order: { "_key" => "asc" } }
    aggs[:limit] = { ranges: limit_ranges }
    aggs
  end
end






