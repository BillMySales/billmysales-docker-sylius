<?php

declare(strict_types=1);

namespace App\Command;

use Doctrine\ORM\EntityManagerInterface;
use Sylius\Component\Addressing\Model\ZoneInterface;
use Sylius\Component\Core\Model\AdminUserInterface;
use Sylius\Component\Core\Model\ChannelInterface;
use Sylius\Component\Core\Model\PaymentMethodInterface;
use Sylius\Component\Core\Model\ShippingMethodInterface;
use Sylius\Component\Core\Model\TaxRateInterface;
use Sylius\Component\Currency\Model\CurrencyInterface;
use Sylius\Component\Locale\Model\LocaleInterface;
use Sylius\Component\Taxation\Model\TaxCategoryInterface;
use Sylius\Resource\Doctrine\Persistence\RepositoryInterface;
use Sylius\Resource\Factory\FactoryInterface;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\DependencyInjection\Attribute\Autowire;

/**
 * Run by the Docker stack's setup service after the migrations, on every
 * `docker compose up`; safe to repeat:
 * - The admin user (SYLIUS_ADMIN_EMAIL / SYLIUS_ADMIN_PASSWORD), if missing
 *   (its password is only set when it's created), with access to the Admin
 *   API.
 * - The locale, currency, country, zone, tax category and rate, shipping
 *   and payment methods of the store (SYLIUS_* variables), each one created
 *   if missing, and the default channel using them when the channel is
 *   created. Later changes in the admin are kept. The channel has no
 *   hostname (like the installer's): it answers on any address, and links in
 *   emails use the request's URL or SYLIUS_URL (DEFAULT_URI) outside
 *   requests. A hostname would make Sylius build them as https://<hostname>,
 *   without the port.
 */
#[AsCommand(name: 'app:stack-setup', description: 'Admin user and store settings of the Docker stack.')]
final class StackSetupCommand extends Command
{
    private const CHANNEL = 'default';

    public function __construct(
        private readonly EntityManagerInterface $em,
        #[Autowire(service: 'sylius.repository.admin_user')] private readonly RepositoryInterface $adminUsers,
        #[Autowire(service: 'sylius.factory.admin_user')] private readonly FactoryInterface $adminUserFactory,
        #[Autowire(service: 'sylius.repository.locale')] private readonly RepositoryInterface $locales,
        #[Autowire(service: 'sylius.factory.locale')] private readonly FactoryInterface $localeFactory,
        #[Autowire(service: 'sylius.repository.currency')] private readonly RepositoryInterface $currencies,
        #[Autowire(service: 'sylius.factory.currency')] private readonly FactoryInterface $currencyFactory,
        #[Autowire(service: 'sylius.repository.country')] private readonly RepositoryInterface $countries,
        #[Autowire(service: 'sylius.factory.country')] private readonly FactoryInterface $countryFactory,
        #[Autowire(service: 'sylius.repository.zone')] private readonly RepositoryInterface $zones,
        #[Autowire(service: 'sylius.factory.zone')] private readonly FactoryInterface $zoneFactory,
        #[Autowire(service: 'sylius.factory.zone_member')] private readonly FactoryInterface $zoneMemberFactory,
        #[Autowire(service: 'sylius.repository.tax_category')] private readonly RepositoryInterface $taxCategories,
        #[Autowire(service: 'sylius.factory.tax_category')] private readonly FactoryInterface $taxCategoryFactory,
        #[Autowire(service: 'sylius.repository.tax_rate')] private readonly RepositoryInterface $taxRates,
        #[Autowire(service: 'sylius.factory.tax_rate')] private readonly FactoryInterface $taxRateFactory,
        #[Autowire(service: 'sylius.repository.channel')] private readonly RepositoryInterface $channels,
        #[Autowire(service: 'sylius.factory.channel')] private readonly FactoryInterface $channelFactory,
        #[Autowire(service: 'sylius.repository.shipping_method')] private readonly RepositoryInterface $shippingMethods,
        #[Autowire(service: 'sylius.factory.shipping_method')] private readonly FactoryInterface $shippingMethodFactory,
        #[Autowire(service: 'sylius.repository.payment_method')] private readonly RepositoryInterface $paymentMethods,
        #[Autowire(service: 'sylius.factory.payment_method')] private readonly FactoryInterface $paymentMethodFactory,
    ) {
        parent::__construct();
    }

    private static function env(string $name, string $default = ''): string
    {
        $value = getenv($name);

        return false === $value || '' === $value ? $default : $value;
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $localeCode = self::env('SYLIUS_LOCALE', 'es_CL');
        $currencyCode = strtoupper(self::env('SYLIUS_CURRENCY', 'CLP'));
        $countryCode = strtoupper(self::env('SYLIUS_COUNTRY', 'CL'));

        $this->adminUser($output, $localeCode);

        /** @var LocaleInterface|null $locale */
        $locale = $this->locales->findOneBy(['code' => $localeCode]);
        if (null === $locale) {
            $locale = $this->localeFactory->createNew();
            $locale->setCode($localeCode);
            $this->em->persist($locale);
        }

        /** @var CurrencyInterface|null $currency */
        $currency = $this->currencies->findOneBy(['code' => $currencyCode]);
        if (null === $currency) {
            $currency = $this->currencyFactory->createNew();
            $currency->setCode($currencyCode);
            $this->em->persist($currency);
        }

        $country = $this->countries->findOneBy(['code' => $countryCode]);
        if (null === $country) {
            $country = $this->countryFactory->createNew();
            $country->setCode($countryCode);
            $country->enable();
            $this->em->persist($country);
        }

        /** @var ZoneInterface|null $zone */
        $zone = $this->zones->findOneBy(['code' => $countryCode]);
        if (null === $zone) {
            $zone = $this->zoneFactory->createNew();
            $zone->setCode($countryCode);
            $zone->setName(self::env('SYLIUS_ZONE_NAME', 'Chile'));
            $zone->setType(ZoneInterface::TYPE_COUNTRY);
            $member = $this->zoneMemberFactory->createNew();
            $member->setCode($countryCode);
            $zone->addMember($member);
            $this->em->persist($zone);
        }

        /** @var TaxCategoryInterface|null $taxCategory */
        $taxCategory = $this->taxCategories->findOneBy(['code' => 'standard']);
        if (null === $taxCategory) {
            $taxCategory = $this->taxCategoryFactory->createNew();
            $taxCategory->setCode('standard');
            $taxCategory->setName(self::env('SYLIUS_TAX_CATEGORY_NAME', 'Afecto'));
            $this->em->persist($taxCategory);
        }

        $taxRate = (float) self::env('SYLIUS_TAX_RATE', '19');
        if ($taxRate > 0 && null === $this->taxRates->findOneBy(['code' => 'standard'])) {
            /** @var TaxRateInterface $rate */
            $rate = $this->taxRateFactory->createNew();
            $rate->setCode('standard');
            $rate->setName(self::env('SYLIUS_TAX_NAME', 'IVA'));
            $rate->setAmount($taxRate / 100);
            $rate->setIncludedInPrice('true' === self::env('SYLIUS_PRICES_INCLUDE_TAX', 'true'));
            $rate->setCalculator('default');
            $rate->setCategory($taxCategory);
            $rate->setZone($zone);
            $this->em->persist($rate);
        }

        /** @var ChannelInterface|null $channel */
        $channel = $this->channels->findOneBy(['code' => self::CHANNEL]);
        if (null === $channel) {
            $output->writeln(sprintf('Channel %s (%s, %s, %s)', self::CHANNEL, $localeCode, $currencyCode, $countryCode));
            $channel = $this->channelFactory->createNew();
            $channel->setCode(self::CHANNEL);
            $channel->setName(self::env('SYLIUS_STORE_NAME', 'Sylius'));
            $channel->setTaxCalculationStrategy('order_items_based');
            $channel->addCurrency($currency);
            $channel->setBaseCurrency($currency);
            $channel->addLocale($locale);
            $channel->setDefaultLocale($locale);
            $channel->addCountry($country);
            $channel->setDefaultTaxZone($zone);
            $channel->setContactEmail(self::env('SYLIUS_MAILER_SENDER_ADDRESS') ?: null);
            $channel->setEnabled(true);
            $this->em->persist($channel);
        }

        if (null === $this->shippingMethods->findOneBy(['code' => 'delivery'])) {
            /** @var ShippingMethodInterface $shipping */
            $shipping = $this->shippingMethodFactory->createNew();
            $shipping->setCode('delivery');
            $shipping->setCurrentLocale($localeCode);
            $shipping->setFallbackLocale($localeCode);
            $shipping->setName(self::env('SYLIUS_SHIPPING_NAME', 'Despacho'));
            $shipping->setZone($zone);
            $shipping->setCalculator('flat_rate');
            $shipping->setConfiguration([self::CHANNEL => ['amount' => 0]]);
            $shipping->addChannel($channel);
            $shipping->setEnabled(true);
            $this->em->persist($shipping);
        }

        if (null === $this->paymentMethods->findOneBy(['code' => 'bank_transfer'])) {
            /** @var PaymentMethodInterface $payment */
            $payment = $this->paymentMethodFactory->createWithGateway('offline');
            $payment->setCode('bank_transfer');
            $payment->getGatewayConfig()?->setGatewayName('offline');
            $payment->setCurrentLocale($localeCode);
            $payment->setFallbackLocale($localeCode);
            $payment->setName(self::env('SYLIUS_PAYMENT_NAME', 'Transferencia bancaria'));
            $payment->addChannel($channel);
            $payment->setEnabled(true);
            $this->em->persist($payment);
        }

        $this->em->flush();
        $output->writeln('Store settings OK');

        return Command::SUCCESS;
    }

    private function adminUser(OutputInterface $output, string $localeCode): void
    {
        $email = self::env('SYLIUS_ADMIN_EMAIL');
        if (null !== $this->adminUsers->findOneBy(['email' => $email])) {
            return;
        }
        /** @var AdminUserInterface $user */
        $user = $this->adminUserFactory->createNew();
        $user->setEmail($email);
        $user->setUsername($email);
        $user->setPlainPassword(self::env('SYLIUS_ADMIN_PASSWORD'));
        $user->setLocaleCode($localeCode);
        // Admin panel and Admin API (/api/v2/admin, JWT).
        $user->addRole('ROLE_API_ACCESS');
        $user->setEnabled(true);
        $this->em->persist($user);
        $this->em->flush();
        $output->writeln(sprintf('Admin user %s created', $email));
    }
}
