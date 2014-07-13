class Notification < ActiveRecord::Base
  attr_accessor :recipients
  attr_accessible :body, :subject, :global, :expires if Mailboxer.protected_attributes?

  belongs_to :sender, :polymorphic => :true
  belongs_to :notified_object, :polymorphic => :true
  has_many :receipts, :dependent => :destroy
  has_many :receivers, :through => :receipts
  has_many :unread_receipts, -> { where(:is_read => false) }, :class_name => 'Receipt', :foreign_key => 'notification_id'

  validates_presence_of :subject, :body

  scope :recipient, lambda { |recipient|
    joins(:receipts).where('receipts.receiver_id' => recipient.id,'receipts.receiver_type' => recipient.class.base_class.to_s)
  }
  scope :with_object, lambda { |obj|
    where('notified_object_id' => obj.id,'notified_object_type' => obj.class.to_s)
  }
  scope :not_trashed, lambda {
    joins(:receipts).where('receipts.trashed' => false)
  }
  scope :unread,  lambda {
    joins(:receipts).where('receipts.is_read' => false)
  }
  scope :global, lambda { where(:global => true) }
  scope :expired, lambda { where("notifications.expires < ?", Time.now) }
  scope :unexpired, lambda {
    where("notifications.expires is NULL OR notifications.expires > ?", Time.now)
  }

  include Concerns::ConfigurableMailer

  class << self
    #Sends a Notification to all the recipients
    def notify_all(recipients,subject,body,obj = nil,sanitize_text = true,notification_code=nil,send_mail=true)
      notification = Notification.new({:body => body, :subject => subject})
      notification.recipients = recipients.respond_to?(:each) ? recipients : [recipients]
      notification.recipients = notification.recipients.uniq if recipients.respond_to?(:uniq)
      notification.notified_object = obj if obj.present?
      notification.notification_code = notification_code if notification_code.present?
      notification.deliver sanitize_text, send_mail
    end

    #Takes a +Receipt+ or an +Array+ of them and returns +true+ if the delivery was
    #successful or +false+ if some error raised
    def successful_delivery? receipts
      case receipts
      when Receipt
        receipts.valid?
        receipts.errors.empty?
      when Array
        receipts.each(&:valid?)
        receipts.all? { |t| t.errors.empty? }
      else
        false
      end
    end
  end

  def expired?
    self.expires.present? && (self.expires < Time.now)
  end

  def expire!
    unless self.expired?
      self.expire
      self.save
    end
  end

  def expire
    unless self.expired?
      self.expires = Time.now - 1.second
    end
  end

  #Delivers a Notification. USE NOT RECOMENDED.
  #Use Mailboxer::Models::Message.notify and Notification.notify_all instead.
  def deliver(should_clean = true, send_mail = true)
    self.clean if should_clean
    temp_receipts = Array.new
    #Receiver receipts
    self.recipients.each do |r|
      msg_receipt = Receipt.new
      msg_receipt.notification = self
      msg_receipt.is_read = false
      msg_receipt.receiver = r
      temp_receipts << msg_receipt
    end
    temp_receipts.each(&:valid?)
    if temp_receipts.all? { |t| t.errors.empty? }
      temp_receipts.each(&:save!)   #Save receipts
      self.recipients.each do |r|
        #Should send an email?
        if Mailboxer.uses_emails
          email_to = r.send(Mailboxer.email_method,self)
          if send_mail && !email_to.blank?
            get_mailer.send_email(self,r).deliver
          end
        end
      end
      self.recipients=nil
    end
    return temp_receipts if temp_receipts.size > 1
    temp_receipts.first
  end

  #Returns the recipients of the Notification
  def recipients
    if @recipients.blank?
      recipients_array = Array.new
      self.receipts.each do |receipt|
        recipients_array << receipt.receiver
      end

      recipients_array
    else
      @recipients
    end
  end

  #Returns the receipt for the participant
  def receipt_for(participant)
    Receipt.notification(self).recipient(participant)
  end

  #Returns the receipt for the participant. Alias for receipt_for(participant)
  def receipts_for(participant)
    receipt_for(participant)
  end

  #Returns if the participant have read the Notification
  def is_unread?(participant)
    return false if participant.nil?
    !self.receipt_for(participant).first.is_read
  end

  def is_read?(participant)
    !self.is_unread?(participant)
  end

  #Returns if the participant have trashed the Notification
  def is_trashed?(participant)
    return false if participant.nil?
    self.receipt_for(participant).first.trashed
  end

  #Returns if the participant have deleted the Notification
  def is_deleted?(participant)
    return false if participant.nil?
    return self.receipt_for(participant).first.deleted
  end

  #Mark the notification as read
  def mark_as_read(participant)
    return if participant.nil?
    self.receipt_for(participant).mark_as_read
  end

  #Mark the notification as unread
  def mark_as_unread(participant)
    return if participant.nil?
    self.receipt_for(participant).mark_as_unread
  end

  #Move the notification to the trash
  def move_to_trash(participant)
    return if participant.nil?
    self.receipt_for(participant).move_to_trash
  end

  #Takes the notification out of the trash
  def untrash(participant)
    return if participant.nil?
    self.receipt_for(participant).untrash
  end

  #Mark the notification as deleted for one of the participant
  def mark_as_deleted(participant)
    return if participant.nil?
    return self.receipt_for(participant).mark_as_deleted
  end

  include ActionView::Helpers::SanitizeHelper

  #Sanitizes the body and subject
  def clean
    unless self.subject.nil?
      self.subject = sanitize self.subject
    end
    self.body = sanitize self.body
  end

  #Returns notified_object. DEPRECATED
  def object
    warn "DEPRECATION WARNING: use 'notify_object' instead of 'object' to get the object associated with the Notification"
    notified_object
  end
end
