require "zdcopy/version"
require "faraday"
require "faraday_middleware"
require "json"
require "pp"
require "active_support/all"

module Zdcopy
  class Main
    DEFAULT_TICKET_FIELD_TYPES = %w(subject description status priority tickettype group assignee)

    def self.prod_client(url: ENV["PROD_ZD_URL"], user: ENV["PROD_ZD_USER"], password: ENV["PROD_ZD_PASSWORD"])
      client = Faraday.new(:url => url) do |conn|
        conn.basic_auth(user, password)
        conn.adapter Faraday.default_adapter
        conn.response :json, :content_type => /\bjson$/
      end

      def client.delete(*_)
        raise "Attempted to delete a resource in production. This is not permitted!"
      end

      def client.post(*_)
        raise "Attempted to create a resource in production. This is not permitted!"
      end

      def client.put(*_)
        raise "Attempted to update a resource in production. This is not permitted!"
      end
    end

    def self.sandbox_client(
      url: ENV["SANDBOX_ZD_URL"],
      user: ENV["SANDBOX_ZD_USER"],
      password: ENV["SANDBOX_ZD_PASSWORD"]
    )
      Faraday.new(:url => url) do |conn|
        conn.basic_auth(user, password)
        conn.adapter Faraday.default_adapter
        conn.response :json, :content_type => /\bjson$/
      end
    end

    def initialize(prod_client: self.class.prod_client, sandbox_client: self.class.sandbox_client)
      @prod_client = prod_client
      @sandbox_client = sandbox_client

      @ticket_field_mapping = {}
      @ticket_form_mapping = {}
      @group_mapping = {}
    end

    def call
      delete_sandbox_groups
      delete_sandbox_triggers
      delete_sandbox_macros
      delete_sandbox_automations
      delete_sandbox_ticket_forms
      delete_sandbox_ticket_fields
      copy_groups
      copy_ticket_fields
      copy_ticket_forms
      copy_automations
      copy_triggers
      copy_macros
    end

    def copy_groups
      copy_resource(
        "groups",
        "groups",
        -> (old, new) {@group_mapping[old["id"]] = new["id"]}
      )
    end

    def copy_ticket_fields
      copy_resource(
        "ticket_fields",
        "ticket_fields",
        -> (old, new) {@ticket_field_mapping[old["id"]] = new["id"]}
      ) {|item| custom_ticket_field?(item) ? item : nil}
    end

    def copy_ticket_forms
      copy_resource(
        "ticket_forms",
        "ticket_forms",
        -> (old, new) {@ticket_form_mapping[old["id"]] = new["id"]}
      ) do |ticket_form|
        ticket_form["ticket_field_ids"] = ticket_form["ticket_field_ids"].map do |old_field_id|
          @ticket_field_mapping[old_field_id]
        end.compact

        ticket_form["in_all_brands"] = true
        ticket_form.delete("restricted_brand_ids")

        ticket_form
      end
    end

    def copy_automations
      copy_resource("automations", "automations/active") do |automation|
        automation["conditions"]["all"] = fix_conditions(automation["conditions"]["all"])
        automation["conditions"]["any"] = fix_conditions(automation["conditions"]["any"])
        automation["actions"] = fix_actions(automation["actions"])

        automation
      end
    end

    def fix_conditions(conditions)
      conditions.map do |condition|
        case condition["field"]
        when "ticket_form_id"
          old_ticket_form_id = condition["value"].to_i
          if @ticket_form_mapping.key?(old_ticket_form_id)
            condition["value"] = @ticket_form_mapping[old_ticket_form_id].to_s
          else
            puts "# Error: failed to translate ticket_form_id: #{old_ticket_form_id}"
          end
        when /custom_fields_*/
          ticket_field_id = condition["field"].split("_").last.to_i
          if @ticket_field_mapping.key?(ticket_field_id)
            condition["field"] = "custom_fields_#{@ticket_field_mapping[ticket_field_id]}"
          else
            puts "# Error: failed to translate ticket_field_id: #{ticket_field_id} (custom_fields_*)"
          end
        when "group_id"
          old_group_id = condition["value"].to_i
          if @group_mapping.key?(old_group_id)
            condition["value"] = @group_mapping[old_group_id].to_s
          else
            puts "# Error: failed to translate group_id: #{old_group_id}"
          end
        end

        condition
      end.compact
    end

    def copy_brands
      copy_resource("brands", "brands")
    end

    def copy_triggers
      copy_resource("triggers", "triggers/active") do |trigger|
        trigger["conditions"]["all"] = fix_conditions(trigger["conditions"]["all"])
        trigger["conditions"]["any"] = fix_conditions(trigger["conditions"]["any"])
        trigger["actions"] = fix_actions(trigger["actions"])

        trigger
      end
    end

    def copy_macros
      copy_resource("macros", "macros/active") do |macro|
        macro["actions"] = fix_actions(macro["actions"])

        macro
      end
    end

    def fix_actions(actions)
      errors = []

      actions_fixed = actions.map do |action|
        next action unless action["field"].start_with?("custom_fields_")

        ticket_field_id = action["field"].split("_").last.to_i
        if @ticket_field_mapping.key?(ticket_field_id)
          ticket_field_name = "custom_fields_#{@ticket_field_mapping[ticket_field_id]}"
          action["field"] = ticket_field_name
        else
          errors << action
          next
        end

        action
      end.compact

      if errors.any?
        puts "# Errors: "
        pp errors
      end

      actions_fixed
    end

    def get_brands
      @prod_client.get("brands").body["brands"]
    end

    def get_ticket_field(id)
      @prod_client.get("ticket_fields/#{id}").body["ticket_field"]
    end

    def get_sandbox_ticket_field(id)
      @sandbox_client.get("ticket_fields/#{id}").body["ticket_field"]
    end

    def get_ticket_fields
      response = @prod_client.get("ticket_fields")

      response.body["ticket_fields"]
    end

    def get_sandbox_ticket_fields
      @sandbox_client.get("ticket_fields").body["ticket_fields"]
    end

    def get_sandbox_brands
      @sandbox_client.get("brands").body["brands"]
    end

    def get_macro(id)
      @prod_client.get("macros/#{id}").body["macro"]
    end

    def get_macros
      get_bulk(@prod_client, "macros/active", "macros")
    end

    def get_triggers
      @prod_client.get("triggers/active").body["triggers"]
    end

    def get_users
      get_bulk(@prod_client, "users", "users")
    end

    def delete_sandbox_groups
      delete_bulk_sandbox_resource("groups", "groups")
    end

    def delete_sandbox_ticket_fields
      delete_bulk_sandbox_resource("ticket_fields", "ticket_fields") do |item|
        custom_ticket_field?(item) ? item : nil
      end
    end

    def delete_sandbox_ticket_forms
      delete_bulk_sandbox_resource("ticket_forms", "ticket_forms")
    end

    def delete_sandbox_macros
      delete_bulk_sandbox_resource("macros/active", "macros")
    end

    def delete_sandbox_automations
      delete_bulk_sandbox_resource("automations/active", "automations")
    end

    def delete_sandbox_triggers
      delete_bulk_sandbox_resource("triggers/active", "triggers")
    end

    def delete_bulk_sandbox_resource(path, resource)
      puts "# Deleting all #{resource} items"

      get_bulk(@sandbox_client, path, resource).each do |item|
        if block_given?
          item = yield(item)
        end

        next if item.nil?

        puts "# Deleting #{item["id"]}"

        response = delete_sandbox_resource(resource, item["id"])

        if !(200...300).include?(response.status)
          puts "# Failed to delete #{resource} #{item["id"]}"
          puts response.body
        end
      end
    end

    def get_sandbox_automations
      get_bulk(@sandbox_client, "automations/active", "automations")
    end

    def get_sandbox_macros
      get_bulk(@sandbox_client, "macros/active", "macros")
    end

    def copy_resource(resource, path, post_create = nil)
      errors = []

      puts "# Copying #{resource}"

      get_bulk(@prod_client, path, resource).each do |item|
        item = yield(item) if block_given?
        next if item.nil?

        puts "# Copying #{item["id"]}"

        response = create_resource(resource, item)

        if (200...300).include?(response.status)
          new_item = response.body[resource.singularize]
          if post_create != nil
            post_create.call(item, new_item)
          end
        else
          puts "# Failed to copy #{resource} #{item["id"]}\nError: #{response.body}"
          errors << response.body
        end
      end

      if errors.any?
        puts "# Errors: "
        pp errors
      end

      nil
    end

    def get_bulk(client, path, resource)
      response = client.get(path)
      objs = response.body[resource]
      next_page = response.body["next_page"]
      while next_page != nil
        query = URI(next_page).query
        response = client.get(path) do |request|
          request.params["page"] = query.split("=").last
        end
        objs.concat(response.body[resource])
        next_page = response.body["next_page"]
      end

      objs
    end

    def create_resource(resource, item)
      @sandbox_client.post(resource) do |request|
        request.headers['Content-Type'] = 'application/json'
        request.body = {resource.singularize => item}.to_json
      end
    end

    def create_sandbox_trigger(trigger)
      @sandbox_client.post("triggers") do |request|
        request.headers['Content-Type'] = 'application/json'
        request.body = {trigger: trigger}.to_json
      end
    end

    def create_sandbox_ticket_field(ticket_field)
      @sandbox_client.post("ticket_fields") do |request|
        request.headers['Content-Type'] = 'application/json'
        request.body = {ticket_field: ticket_field}.to_json
      end
    end

    def create_sandbox_brand(brand)
      @sandbox_client.post("brands") do |request|
        request.headers['Content-Type'] = 'application/json'
        request.body = {brand: brand}.to_json
      end
    end

    def create_sandbox_macro(macro)
      @sandbox_client.post("macros") do |request|
        request.headers['Content-Type'] = 'application/json'
        request.body = {macro: macro}.to_json
      end
    end

    def delete_sandbox_ticket_field(id)
      @sandbox_client.delete("ticket_fields/#{id}")
    end

    def delete_sandbox_resource(name, id)
      @sandbox_client.delete("#{name}/#{id}")
    end

    def delete_sandbox_trigger(id)
      @sandbox_client.delete("triggers/#{id}")
    end

    def custom_ticket_field?(ticket_field)
      !DEFAULT_TICKET_FIELD_TYPES.include?(ticket_field["type"])
    end
  end
end
